"""Read-only diagnostic tools + Claude chat backend for the GPU rig dashboard.

Everything here is read-only: no tool can modify rig state, restart services,
change pricing, or change power limits — only report on them. Diagnostics run
local commands with fixed argument lists (never shell=True, never request
input interpolated into a shell string), and the kaalia-log search uses
Python's re module directly rather than shelling out to grep, so there is no
command-injection surface even though /api/diag and /api/chat are reachable
without auth (same posture as the existing /api/data and /api/peer endpoints
on this server).

The Anthropic API key lives only here, server-side, read from
/etc/gpu_monitor.conf (root-only, 600) — it is never sent to the browser.
"""
import os, re, json, glob, subprocess, time, urllib.request, urllib.error, urllib.parse
from collections import deque

CONF_FILE = "/etc/gpu_monitor.conf"
KAALIA_GLOB = "/var/lib/vastai_kaalia/kaalia.log*"
PING_TARGET = "1.1.1.1"           # fixed — never derived from a request
KAALIA_SCAN_LINES = 5000          # bounds worst-case regex work per request
MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-haiku-4-5")
MAX_TOOL_TURNS = 6


def _conf_value(key):
    """Read KEY="value" out of /etc/gpu_monitor.conf without sourcing it —
    that file is bash syntax, but we only need a plain string here, so a
    regex read avoids ever executing it as code from Python."""
    try:
        text = open(CONF_FILE).read()
    except OSError:
        return ""
    m = re.search(rf'^{key}=["\']?([^"\'\n]*)["\']?\s*$', text, re.MULTILINE)
    return m.group(1) if m else ""


ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY") or _conf_value("ANTHROPIC_API_KEY")
CHAT_ENABLED = bool(ANTHROPIC_API_KEY)

_client = None


def _get_client():
    global _client
    if _client is None:
        from anthropic import Anthropic
        _client = Anthropic(api_key=ANTHROPIC_API_KEY)
    return _client


# ── Local diagnostics (read-only, fixed argv, no shell) ─────────────────

def diag_gpu():
    try:
        out = subprocess.run(
            ["nvidia-smi",
             "--query-gpu=index,name,temperature.gpu,power.draw,power.limit,utilization.gpu,memory.used,memory.total",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        return {"error": f"nvidia-smi unavailable: {e}"}
    if out.returncode != 0:
        return {"error": out.stderr.strip() or "nvidia-smi failed"}
    gpus = []
    for line in out.stdout.strip().splitlines():
        f = [x.strip() for x in line.split(",")]
        if len(f) < 8:
            continue
        gpus.append({
            "index": f[0], "name": f[1], "temp_c": f[2], "power_draw_w": f[3],
            "power_limit_w": f[4], "util_pct": f[5], "mem_used_mib": f[6], "mem_total_mib": f[7],
        })
    return {"gpus": gpus}


def get_cpu_temp():
    """Same hwmon-scan logic as get_cpu_temp() in gpu_monitor.sh, reimplemented
    here since this is a separate (Python) process."""
    for hw in glob.glob("/sys/class/hwmon/hwmon*"):
        try:
            name = open(f"{hw}/name").read().strip()
        except OSError:
            continue
        if name not in ("k10temp", "zenpower", "coretemp"):
            continue
        temps = []
        for tf in glob.glob(f"{hw}/temp*_input"):
            try:
                temps.append(int(open(tf).read().strip()))
            except (OSError, ValueError):
                pass
        if temps:
            return max(temps) // 1000
    return None


def diag_cpu():
    try:
        load1, load5, load15 = open("/proc/loadavg").read().split()[:3]
    except OSError:
        load1 = load5 = load15 = None
    return {
        "load1": load1, "load5": load5, "load15": load15,
        "cpu_count": os.cpu_count(),
        "cpu_temp_c": get_cpu_temp(),
    }


def diag_network():
    try:
        ip_out = subprocess.run(["ip", "-brief", "addr"], capture_output=True, text=True, timeout=5).stdout
    except (FileNotFoundError, subprocess.TimeoutExpired):
        ip_out = ""
    interfaces = [l.strip() for l in ip_out.splitlines() if l.strip()]
    reachable, rtt_ms = False, None
    try:
        p = subprocess.run(["ping", "-c", "1", "-W", "2", PING_TARGET],
                            capture_output=True, text=True, timeout=5)
        reachable = p.returncode == 0
        if reachable:
            m = re.search(r"time=([\d.]+)", p.stdout)
            if m:
                rtt_ms = float(m.group(1))
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return {"interfaces": interfaces, "internet_reachable": reachable, "ping_ms": rtt_ms, "ping_target": PING_TARGET}


def diag_kaalia(pattern=None, lines=50):
    try:
        lines = max(1, min(int(lines or 50), 200))
    except (TypeError, ValueError):
        lines = 50
    files = sorted(glob.glob(KAALIA_GLOB), key=os.path.getmtime, reverse=True)
    if not files:
        return {"error": "no kaalia.log found on this rig"}
    if pattern and len(pattern) > 200:
        return {"error": "pattern too long"}
    try:
        rx = re.compile(pattern) if pattern else None
    except re.error as e:
        return {"error": f"invalid regex: {e}"}
    buf = deque(maxlen=KAALIA_SCAN_LINES)
    for fp in files:
        try:
            for line in open(fp, errors="replace"):
                buf.append(line.rstrip("\n"))
        except OSError:
            continue
    scanned = len(buf)
    matches = [l for l in buf if rx.search(l)] if rx else list(buf)
    matches = matches[-lines:]
    return {"matches": matches, "scanned_lines": scanned, "returned": len(matches)}


_DIAG_FUNCS = {"gpu": diag_gpu, "cpu": diag_cpu, "network": diag_network}


def handle_diag_request(kind, query):
    """query: dict from urllib.parse.parse_qs (values are lists)."""
    if kind == "kaalia":
        pattern = (query.get("pattern") or [None])[0]
        lines = (query.get("lines") or [50])[0]
        return diag_kaalia(pattern, lines)
    fn = _DIAG_FUNCS.get(kind)
    if not fn:
        return {"error": f"unknown diagnostic kind '{kind}'"}
    return fn()


# ── Tool-use loop (server-side only — the API key never reaches the browser) ──

TOOLS = [
    {
        "name": "get_gpu_status",
        "description": "Read-only live GPU status (temp, power draw/limit, utilization, memory) for one named rig.",
        "input_schema": {"type": "object", "properties": {
            "rig": {"type": "string", "description": "Rig name, e.g. Zappa1, Zappa2, Zappa3"}},
            "required": ["rig"]},
    },
    {
        "name": "get_cpu_status",
        "description": "Read-only CPU load average, core count, and package temperature for one named rig.",
        "input_schema": {"type": "object", "properties": {
            "rig": {"type": "string", "description": "Rig name"}},
            "required": ["rig"]},
    },
    {
        "name": "get_network_status",
        "description": "Read-only network interface list and internet reachability for one named rig.",
        "input_schema": {"type": "object", "properties": {
            "rig": {"type": "string", "description": "Rig name"}},
            "required": ["rig"]},
    },
    {
        "name": "search_kaalia_log",
        "description": ("Read-only search of the Vast.ai kaalia daemon log on one named rig. "
                         "Pass a regex 'pattern' to filter (e.g. an error keyword or session id), "
                         "or omit it to get the most recent lines. Useful for rental/session issues."),
        "input_schema": {"type": "object", "properties": {
            "rig": {"type": "string", "description": "Rig name"},
            "pattern": {"type": "string", "description": "Optional regex filter"},
            "lines": {"type": "integer", "description": "Max lines to return (default 50, max 200)"}},
            "required": ["rig"]},
    },
]

SYSTEM_PROMPT = (
    "You are a read-only diagnostic assistant for a small home GPU-rental rig fleet "
    "(Vast.ai hosts). You have two information sources: (1) a JSON stats digest in the "
    "user message — revenue, rental status, temps, GPU processes, ask price, per rig — "
    "and (2) live read-only tools for GPU/CPU/network status and kaalia-log search on any "
    "named rig. No tool can change, restart, or configure anything on any rig — every tool "
    "only reports state. If asked to change a price, power limit, or anything else, say "
    "you're read-only and can't. Answer concisely — a sentence or a short list — suitable "
    "for a chat bubble; <b> and <br> tags are fine, nothing else. If a rig name in the "
    "question doesn't match any known rig, say so instead of guessing."
)


def _resolve_rig(name, self_name, peer_urls, peer_names):
    """Returns None for the local rig, a peer base URL for a remote rig, or
    the sentinel "__unknown__" if the name doesn't match anything."""
    n = (name or "").strip().lower()
    if not n or n == self_name.lower():
        return None
    for i, pname in enumerate(peer_names):
        if pname.lower() == n and i < len(peer_urls):
            return peer_urls[i]
    for i, url in enumerate(peer_urls):
        if n in (f"rig {i + 2}", f"rig{i + 2}"):
            return url
    return "__unknown__"


def _run_tool(name, tool_input, self_name, peer_urls, peer_names):
    rig = tool_input.get("rig", "")
    peer = _resolve_rig(rig, self_name, peer_urls, peer_names)
    if peer == "__unknown__":
        known = [self_name] + list(peer_names)
        return {"error": f"unknown rig '{rig}'. Known rigs: {', '.join(known)}"}
    kind = {"get_gpu_status": "gpu", "get_cpu_status": "cpu",
            "get_network_status": "network", "search_kaalia_log": "kaalia"}[name]
    if peer is None:
        if kind == "kaalia":
            return diag_kaalia(tool_input.get("pattern"), tool_input.get("lines", 50))
        return _DIAG_FUNCS[kind]()
    # Remote rig: proxy the same diagnostic over HTTP, server-side only —
    # mirrors the existing /api/peer proxy pattern in server.py.
    qs = ""
    if kind == "kaalia":
        parts = []
        if tool_input.get("pattern"):
            parts.append("pattern=" + urllib.parse.quote(tool_input["pattern"]))
        if tool_input.get("lines"):
            parts.append("lines=" + str(int(tool_input["lines"])))
        qs = "?" + "&".join(parts) if parts else ""
    try:
        req = urllib.request.urlopen(f"{peer}/api/diag/{kind}{qs}", timeout=8)
        return json.loads(req.read())
    except Exception as e:
        return {"error": f"couldn't reach {rig}: {e}"}


def run_chat(question, context, self_name, peer_urls, peer_names):
    if not CHAT_ENABLED:
        return "Chat isn't configured on this rig (no ANTHROPIC_API_KEY in /etc/gpu_monitor.conf)."
    client = _get_client()
    user_text = f"Rig stats digest (JSON):\n{json.dumps(context)}\n\nQuestion: {question}"
    messages = [{"role": "user", "content": user_text}]
    for _ in range(MAX_TOOL_TURNS):
        resp = client.messages.create(
            model=MODEL, max_tokens=700, system=SYSTEM_PROMPT,
            tools=TOOLS, messages=messages,
        )
        if resp.stop_reason != "tool_use":
            text = "".join(b.text for b in resp.content if b.type == "text").strip()
            return text or "(no answer)"
        messages.append({"role": "assistant", "content": resp.content})
        results = []
        for block in resp.content:
            if block.type == "tool_use":
                out = _run_tool(block.name, block.input, self_name, peer_urls, peer_names)
                results.append({"type": "tool_result", "tool_use_id": block.id, "content": json.dumps(out)})
        messages.append({"role": "user", "content": results})
    return "That took too many steps to answer — try a more specific question."


# ── Simple per-IP + global rate limit — this endpoint costs real money per
# call and, like the rest of this dashboard, has no auth in front of it. ──

_rate_state = {"per_ip": {}, "total": deque()}


def rate_limited(client_ip, per_ip_per_hour=20, total_per_hour=100):
    now = time.time()
    hour_ago = now - 3600
    total = _rate_state["total"]
    while total and total[0] < hour_ago:
        total.popleft()
    if len(total) >= total_per_hour:
        return True
    bucket = _rate_state["per_ip"].setdefault(client_ip, deque())
    while bucket and bucket[0] < hour_ago:
        bucket.popleft()
    if len(bucket) >= per_ip_per_hour:
        return True
    bucket.append(now)
    total.append(now)
    return False
