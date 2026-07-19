"""Read-only diagnostic tools + a swappable LLM chat backend for the GPU rig
dashboard.

Everything here is read-only: no tool can modify rig state, restart services,
change pricing, or change power limits — only report on them. Diagnostics run
local commands with fixed argument lists (never shell=True, never request
input interpolated into a shell string), and the kaalia-log search uses
Python's re module directly rather than shelling out to grep, so there is no
command-injection surface even though /api/diag and /api/chat are reachable
without auth (same posture as the existing /api/data and /api/peer endpoints
on this server).

The active LLM provider is picked by LLM_PROVIDER (env or /etc/gpu_monitor.conf,
default "openai"); its API key lives only here, server-side, read from the
same conf file (root-only, 600) — it is never sent to the browser. To add a
new provider (or switch back to one already here) later: implement
LLMProvider.complete() for it, add it to PROVIDERS, and set LLM_PROVIDER +
its own <PROVIDER>_API_KEY in the conf. Nothing else in this file, in
server.py, or in the frontend needs to change — run_chat() and every tool
are provider-agnostic.
"""
import os, re, json, glob, subprocess, time, urllib.request, urllib.error, urllib.parse
from abc import ABC, abstractmethod
from collections import deque
from dataclasses import dataclass, field
from typing import Optional
import history_api

CONF_FILE = "/etc/gpu_monitor.conf"
KAALIA_GLOB = "/var/lib/vastai_kaalia/kaalia.log*"
PING_TARGET = "1.1.1.1"           # fixed — never derived from a request
KAALIA_SCAN_LINES = 5000          # bounds worst-case regex work per request
DATA_FILE = os.environ.get("GPU_DATA", "/var/log/gpu_monitor_data.jsonl")
PROMETHEUS_URL = os.environ.get("PROMETHEUS_URL", "http://localhost:9090")
MAX_TOOL_TURNS = 6
LLM_REQUEST_TIMEOUT = 25          # seconds — so a stuck upstream call fails fast instead of hanging


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


def _safe_json(s):
    try:
        return json.loads(s or "{}")
    except json.JSONDecodeError:
        return {}


# ── LLM provider interface ──────────────────────────────────────────────
#
# run_chat() below drives the tool-use loop entirely in terms of this
# provider-agnostic shape:
#   - a "turn" is one of {"role":"user","text":...},
#     {"role":"assistant","text":..., "tool_calls":[ToolCall,...]},
#     {"role":"tool_result","tool_call_id":..., "content":...}
#   - a provider's complete() takes the running list of turns + the tool
#     schema and returns a single normalized AssistantTurn (either final text,
#     or one or more tool calls to run before asking the provider again).
# Each concrete provider is responsible for translating this shape to and
# from its own wire format — the rest of the file never sees an OpenAI- or
# Anthropic-shaped message.

@dataclass
class ToolCall:
    id: str
    name: str
    arguments: dict


@dataclass
class AssistantTurn:
    text: Optional[str]
    tool_calls: list = field(default_factory=list)


class LLMProvider(ABC):
    key_conf_name: str = ""      # e.g. "OPENAI_API_KEY"
    model_conf_name: str = ""    # e.g. "OPENAI_MODEL"
    default_model: str = ""

    def __init__(self):
        self.api_key = os.environ.get(self.key_conf_name) or _conf_value(self.key_conf_name)
        self.model = os.environ.get(self.model_conf_name) or _conf_value(self.model_conf_name) or self.default_model
        self._client = None

    def is_available(self):
        return bool(self.api_key)

    @abstractmethod
    def complete(self, system_prompt, turns, tools):
        """Returns one AssistantTurn given the full conversation so far."""
        ...


def _wire_tools_openai(tools):
    return [{"type": "function", "function": {
        "name": t["name"], "description": t["description"], "parameters": t["parameters"]}}
        for t in tools]


def _to_openai_messages(system_prompt, turns):
    messages = [{"role": "system", "content": system_prompt}]
    for t in turns:
        if t["role"] == "user":
            messages.append({"role": "user", "content": t["text"]})
        elif t["role"] == "assistant":
            messages.append({
                "role": "assistant",
                "content": t.get("text"),
                "tool_calls": [
                    {"id": tc.id, "type": "function",
                     "function": {"name": tc.name, "arguments": json.dumps(tc.arguments)}}
                    for tc in t["tool_calls"]
                ],
            })
        elif t["role"] == "tool_result":
            messages.append({"role": "tool", "tool_call_id": t["tool_call_id"], "content": json.dumps(t["content"])})
    return messages


class OpenAIProvider(LLMProvider):
    """Chat Completions API with function calling."""
    key_conf_name = "OPENAI_API_KEY"
    model_conf_name = "OPENAI_MODEL"
    # gpt-4o-mini has the largest complimentary daily token allowance (10M/day)
    # under OpenAI's data-sharing free-tokens program — a good default for a
    # low-volume personal Q&A backend. See RIGS.md for how to enable it.
    default_model = "gpt-4o-mini"

    def complete(self, system_prompt, turns, tools):
        from openai import OpenAI
        if self._client is None:
            self._client = OpenAI(api_key=self.api_key, timeout=LLM_REQUEST_TIMEOUT)
        messages = _to_openai_messages(system_prompt, turns)
        resp = self._client.chat.completions.create(
            model=self.model, max_tokens=700, tools=_wire_tools_openai(tools), messages=messages,
        )
        msg = resp.choices[0].message
        if not msg.tool_calls:
            return AssistantTurn(text=msg.content, tool_calls=[])
        calls = [ToolCall(id=tc.id, name=tc.function.name, arguments=_safe_json(tc.function.arguments))
                 for tc in msg.tool_calls]
        return AssistantTurn(text=msg.content, tool_calls=calls)


def _wire_tools_anthropic(tools):
    return [{"name": t["name"], "description": t["description"], "input_schema": t["parameters"]}
            for t in tools]


def _to_anthropic_messages(turns):
    """Anthropic requires all tool_results answering one assistant turn to be
    combined into a single following user message (list of tool_result
    blocks), so consecutive tool_result turns here get merged into one."""
    messages = []
    i = 0
    while i < len(turns):
        t = turns[i]
        if t["role"] == "user":
            messages.append({"role": "user", "content": t["text"]})
            i += 1
        elif t["role"] == "assistant":
            content = []
            if t.get("text"):
                content.append({"type": "text", "text": t["text"]})
            for tc in t["tool_calls"]:
                content.append({"type": "tool_use", "id": tc.id, "name": tc.name, "input": tc.arguments})
            messages.append({"role": "assistant", "content": content})
            i += 1
        else:  # tool_result — gather the run of consecutive results
            group = []
            while i < len(turns) and turns[i]["role"] == "tool_result":
                tr = turns[i]
                group.append({"type": "tool_result", "tool_use_id": tr["tool_call_id"],
                              "content": json.dumps(tr["content"])})
                i += 1
            messages.append({"role": "user", "content": group})
    return messages


class AnthropicProvider(LLMProvider):
    """Messages API with tool use."""
    key_conf_name = "ANTHROPIC_API_KEY"
    model_conf_name = "ANTHROPIC_MODEL"
    default_model = "claude-haiku-4-5"  # cheapest/fastest tier — fits this low-volume Q&A use

    def complete(self, system_prompt, turns, tools):
        from anthropic import Anthropic
        if self._client is None:
            self._client = Anthropic(api_key=self.api_key, timeout=LLM_REQUEST_TIMEOUT)
        messages = _to_anthropic_messages(turns)
        resp = self._client.messages.create(
            model=self.model, max_tokens=700, system=system_prompt,
            tools=_wire_tools_anthropic(tools), messages=messages,
        )
        text = "".join(b.text for b in resp.content if b.type == "text").strip() or None
        if resp.stop_reason != "tool_use":
            return AssistantTurn(text=text, tool_calls=[])
        calls = [ToolCall(id=b.id, name=b.name, arguments=b.input) for b in resp.content if b.type == "tool_use"]
        return AssistantTurn(text=text, tool_calls=calls)


PROVIDERS = {"openai": OpenAIProvider, "anthropic": AnthropicProvider}

LLM_PROVIDER_NAME = (os.environ.get("LLM_PROVIDER") or _conf_value("LLM_PROVIDER") or "openai").strip().lower()

_provider = None


def _get_provider():
    global _provider
    if _provider is None:
        cls = PROVIDERS.get(LLM_PROVIDER_NAME)
        if not cls:
            raise ValueError(f"unknown LLM_PROVIDER '{LLM_PROVIDER_NAME}' (known: {', '.join(PROVIDERS)})")
        _provider = cls()
    return _provider


try:
    CHAT_ENABLED = _get_provider().is_available()
except ValueError:
    CHAT_ENABLED = False


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


def diag_rental():
    """Current rental state for THIS rig, from the same JSONL event log the
    dashboard itself reads (/api/data) — so this tool answers correctly even
    when called with no client-supplied stats digest (e.g. a bare API call)."""
    try:
        lines = open(DATA_FILE).read().splitlines()
    except OSError:
        return {"error": "no event log found on this rig"}
    last_start = last_end = last_price = None
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = ev.get("type")
        if t == "rental_start":
            last_start = ev
        elif t == "rental_end":
            last_end = ev
        elif t == "price_change":
            last_price = ev
    rented = bool(last_start) and (not last_end or last_end.get("ts", "") < last_start.get("ts", ""))
    result = {"rented": rented}
    if rented:
        result.update({
            "gpus": last_start.get("gpus"),
            "rate": last_start.get("rate"),
            "workload_type": last_start.get("workload_type"),
            "expire_date": last_start.get("expire_date"),
        })
    if last_price:
        result["ask_price"] = last_price.get("new_price")
    return result


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


def get_history(metric, rig=None, hours=24):
    """Historical trend summary from the central Prometheus (hub only — see
    history_api.py). Returns min/max/avg/first/latest per series rather than
    the raw time series, since the LLM only needs a compact numeric summary
    to reason about a trend question, not thousands of samples. Prometheus
    is central regardless of which rig's dashboard process the chat is
    actually running in, so — unlike the other diag tools — this never
    proxies to a peer; it always queries THIS process's PROMETHEUS_URL.
    Rig names are lowercased to match the `rig` label's convention (the
    actual hostname; see prom_exporter.py's docstring for why display names
    like "Zappa1" must never be used as the label value)."""
    try:
        hours = max(1, min(24 * 90, int(hours or 24)))
    except (TypeError, ValueError):
        hours = 24
    rig_norm = (rig or "").strip().lower() or None
    window_s = hours * 3600
    end = int(time.time())
    start = end - window_s
    step = max(60, window_s // 200)
    try:
        query = history_api.build_query(metric, rig=rig_norm, window_s=step)
        result = history_api.query_range(PROMETHEUS_URL, query, start, end, step)
    except Exception as e:
        return {"error": str(e)}
    series = result.get("data", {}).get("result", [])
    if not series:
        return {"metric": metric, "rig": rig_norm, "hours": hours, "summary": [],
                "note": "no data in this window (check the rig name, or Prometheus may not be reachable)"}
    summary = []
    for s in series:
        vals = [float(v[1]) for v in s["values"]]
        if not vals:
            continue
        summary.append({
            "labels": s["metric"],
            "count": len(vals),
            "min": round(min(vals), 4),
            "max": round(max(vals), 4),
            "avg": round(sum(vals) / len(vals), 4),
            "first": round(vals[0], 4),
            "latest": round(vals[-1], 4),
        })
    return {"metric": metric, "rig": rig_norm, "hours": hours, "summary": summary}


_DIAG_FUNCS = {"gpu": diag_gpu, "cpu": diag_cpu, "network": diag_network, "rental": diag_rental}


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


# ── Tools (provider-agnostic: name/description/JSON-schema parameters) ───

TOOLS = [
    {
        "name": "get_rental_status",
        "description": ("Read-only current rental status for one named rig, straight from its event "
                         "log: whether it's rented right now, GPU count/rate/workload if so, and its "
                         "current ask price. Use this (not the stats digest alone) whenever asked "
                         "whether a rig is rented/free/busy/idle."),
        "parameters": {"type": "object", "properties": {
            "rig": {"type": "string", "description": "Rig name, e.g. Zappa1, Zappa2, Zappa3"}},
            "required": ["rig"]},
    },
    {
        "name": "get_gpu_status",
        "description": "Read-only live GPU status (temp, power draw/limit, utilization, memory) for one named rig.",
        "parameters": {"type": "object", "properties": {
            "rig": {"type": "string", "description": "Rig name, e.g. Zappa1, Zappa2, Zappa3"}},
            "required": ["rig"]},
    },
    {
        "name": "get_cpu_status",
        "description": "Read-only CPU load average, core count, and package temperature for one named rig.",
        "parameters": {"type": "object", "properties": {
            "rig": {"type": "string", "description": "Rig name"}},
            "required": ["rig"]},
    },
    {
        "name": "get_network_status",
        "description": "Read-only network interface list and internet reachability for one named rig.",
        "parameters": {"type": "object", "properties": {
            "rig": {"type": "string", "description": "Rig name"}},
            "required": ["rig"]},
    },
    {
        "name": "search_kaalia_log",
        "description": ("Read-only search of the Vast.ai kaalia daemon log on one named rig. "
                         "Pass a regex 'pattern' to filter (e.g. an error keyword or session id), "
                         "or omit it to get the most recent lines. Useful for rental/session issues."),
        "parameters": {"type": "object", "properties": {
            "rig": {"type": "string", "description": "Rig name"},
            "pattern": {"type": "string", "description": "Optional regex filter"},
            "lines": {"type": "integer", "description": "Max lines to return (default 50, max 200)"}},
            "required": ["rig"]},
    },
    {
        "name": "get_history",
        "description": ("Read-only historical trend for one metric, from the fleet's Prometheus "
                         "history (live scraping plus best-effort backfill back to ~June 8). Use this "
                         "for ANY question about change OVER TIME — trends, averages, min/max, "
                         "'how has X been', 'last week', 'this month' — rather than the get_*_status "
                         "tools, which only report the CURRENT instant. Returns a compact min/max/avg/"
                         "first/latest summary per matching series, not raw samples."),
        "parameters": {"type": "object", "properties": {
            "metric": {"type": "string", "enum": sorted(history_api.metric_names()),
                       "description": "Which metric to summarize"},
            "rig": {"type": "string", "description": "Optional rig name filter; omit to cover all rigs"},
            "hours": {"type": "integer",
                      "description": "Lookback window in hours, ending now (default 24, max 2160 = 90 days)"}},
            "required": ["metric"]},
    },
]

SYSTEM_PROMPT = (
    "You are a read-only diagnostic assistant for a small home GPU-rental rig fleet "
    "(Vast.ai hosts). You have three information sources: (1) a JSON stats digest in the "
    "user message — revenue, rental status, temps, GPU processes, ask price, per rig — "
    "(2) live read-only tools for rental status, GPU/CPU/network status, and kaalia-log "
    "search on any named rig, for the CURRENT instant, and (3) get_history, for trends over "
    "time (temps, prices, rates, revenue) — back to live scraping start, plus best-effort "
    "backfilled data to ~June 8. Use get_history whenever the question is about change over "
    "time ('trending', 'this week', 'last month', 'average', 'has it gone up') rather than "
    "the current status tools. The stats digest may be stale or absent (e.g. a direct API "
    "call); always call get_rental_status for that rig before answering a rented/free/busy/ "
    "idle question, rather than trusting the digest or guessing. No tool can change, restart, "
    "or configure anything on any rig — every tool only reports state. If asked to change a "
    "price, power limit, or anything else, say you're read-only and can't. Answer concisely — "
    "a sentence or a short list — suitable for a chat bubble; <b> and <br> tags are fine, "
    "nothing else. If a rig name in the question doesn't match any known rig, say so instead "
    "of guessing."
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
    if name == "get_history":
        # Prometheus is central (hub only) regardless of which rig's process
        # this chat happens to be running in — never proxy this one to a
        # peer like the other tools do.
        return get_history(tool_input.get("metric"), tool_input.get("rig"), tool_input.get("hours", 24))
    rig = tool_input.get("rig", "")
    peer = _resolve_rig(rig, self_name, peer_urls, peer_names)
    if peer == "__unknown__":
        known = [self_name] + list(peer_names)
        return {"error": f"unknown rig '{rig}'. Known rigs: {', '.join(known)}"}
    kind = {"get_rental_status": "rental", "get_gpu_status": "gpu", "get_cpu_status": "cpu",
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
    """Provider-agnostic tool-use loop — see the LLM provider interface
    section above. Swapping providers never touches this function."""
    if not CHAT_ENABLED:
        return (f"Chat isn't configured on this rig — set {LLM_PROVIDER_NAME.upper()}_API_KEY "
                f"in /etc/gpu_monitor.conf (or LLM_PROVIDER to a different configured backend).")
    provider = _get_provider()
    user_text = f"Rig stats digest (JSON):\n{json.dumps(context)}\n\nQuestion: {question}"
    turns = [{"role": "user", "text": user_text}]
    for _ in range(MAX_TOOL_TURNS):
        try:
            turn = provider.complete(SYSTEM_PROMPT, turns, TOOLS)
        except ImportError as e:
            return (f"LLM_PROVIDER is '{LLM_PROVIDER_NAME}' but its SDK isn't installed: {e}. "
                    f"Run: pip3 install {LLM_PROVIDER_NAME}")
        if not turn.tool_calls:
            return (turn.text or "").strip() or "(no answer)"
        turns.append({"role": "assistant", "text": turn.text, "tool_calls": turn.tool_calls})
        for tc in turn.tool_calls:
            out = _run_tool(tc.name, tc.arguments, self_name, peer_urls, peer_names)
            turns.append({"role": "tool_result", "tool_call_id": tc.id, "content": out})
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
