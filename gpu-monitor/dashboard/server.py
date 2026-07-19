#!/usr/bin/env python3
"""GPU Monitor dashboard server — serves UI + /api/data from JSONL log."""
import http.server, json, os, socket, urllib.request, urllib.error, urllib.parse
from pathlib import Path
import assistant
import prom_exporter
import history_api
import profit_api
import occupancy_api
import daily_summary_api
import events_api
import time

DATA_FILE  = os.environ.get("GPU_DATA", "/var/log/gpu_monitor_data.jsonl")
STATE_FILE = os.environ.get("GPU_STATE_FILE", "/var/tmp/gpu_monitor_vastai_state")
PORT      = int(os.environ.get("DASHBOARD_PORT", "8080"))
DASH_DIR  = Path(__file__).parent
PROMETHEUS_URL = os.environ.get("PROMETHEUS_URL", "http://localhost:9090")

# Peers this server proxies for the combined dashboard (LAN and public).
# PEER_URLS: comma-separated base URLs, e.g. "http://192.168.1.196:8081,http://192.168.1.150:8082"
# PEER_NAMES: optional comma-separated display names matching PEER_URLS order.
# Kept PEER_URL (singular) working for backward compatibility with older installs.
_legacy_peer = os.environ.get("PEER_URL", "").rstrip("/")
PEER_URLS = [u.strip().rstrip("/") for u in os.environ.get("PEER_URLS", "").split(",") if u.strip()]
if not PEER_URLS and _legacy_peer:
    PEER_URLS = [_legacy_peer]
PEER_NAMES = [n.strip() for n in os.environ.get("PEER_NAMES", "").split(",") if n.strip()]
SELF_NAME  = os.environ.get("SELF_NAME", "").strip() or socket.gethostname()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # Exact-match routes below must ignore any query string (e.g.
        # /history?rig=Zappa2 from the rig-drilldown deep link) — matching on
        # self.path directly 404s the instant a query string is present.
        path_only = self.path.split("?", 1)[0]
        if self.path.startswith("/metrics"):
            self._serve_metrics()
        elif self.path.startswith("/api/data"):
            self._serve_data()
        elif self.path.startswith("/api/config"):
            self._serve_config()
        elif self.path.startswith("/api/peer"):
            self._serve_peer()
        elif self.path.startswith("/api/diag/"):
            self._serve_diag()
        elif self.path.startswith("/api/history/rigs"):
            self._serve_history_rigs()
        elif self.path.startswith("/api/history"):
            self._serve_history()
        elif self.path.startswith("/api/profit"):
            self._serve_profit()
        elif self.path.startswith("/api/occupancy"):
            self._serve_occupancy()
        elif self.path.startswith("/api/daily-summary"):
            self._serve_daily_summary()
        elif self.path.startswith("/api/events"):
            self._serve_events()
        elif path_only in ("/history", "/history.html"):
            self._serve_file(DASH_DIR / "history.html", "text/html; charset=utf-8")
        elif path_only in ("/", "/index.html"):
            # On the hub (peers configured) open straight on the all-rigs view so
            # dash.ronyzap.com lands on /combined; standalone rigs keep the single view.
            if PEER_URLS:
                self.send_response(302)
                self.send_header("Location", "/combined")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
            else:
                self._serve_file(DASH_DIR / "index.html", "text/html; charset=utf-8")
        elif path_only in ("/combined", "/combined.html"):
            self._serve_file(DASH_DIR / "combined.html", "text/html; charset=utf-8")
        elif path_only in ("/market", "/market.html"):
            self._serve_file(DASH_DIR / "market.html", "text/html; charset=utf-8")
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path.startswith("/api/chat"):
            self._serve_chat()
        else:
            self.send_error(404)

    def _serve_metrics(self):
        """Prometheus scrape target — current per-GPU/per-machine state, no
        auth (same posture as /api/data; this is a private LAN endpoint)."""
        try:
            body = prom_exporter.render_metrics(DATA_FILE, STATE_FILE).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except BrokenPipeError:
            pass
        except Exception as e:
            try: self.send_error(500, str(e))
            except BrokenPipeError: pass

    def _serve_profit(self):
        """Live + today/month-to-date profit metrics (hub only — see
        profit_api.py). No query params; always covers every rig Prometheus
        has data for."""
        try:
            result = profit_api.handle_profit_request(PROMETHEUS_URL, time.time())
            body = json.dumps(result).encode()
            status = 200
        except Exception as e:
            body = json.dumps({"error": str(e)}).encode()
            status = 400
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _serve_occupancy(self):
        """Occupancy analytics (hub only — see occupancy_api.py). Query
        param: hours (window size, default 24)."""
        _, _, qs = self.path.partition("?")
        query = urllib.parse.parse_qs(qs)
        try:
            result = occupancy_api.handle_occupancy_request(PROMETHEUS_URL, query, time.time())
            body = json.dumps(result).encode()
            status = 200
        except Exception as e:
            body = json.dumps({"error": str(e)}).encode()
            status = 400
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _serve_daily_summary(self):
        """Previous full UTC calendar day's revenue/electricity/profit,
        occupancy, temps, and price-change activity (hub only — see
        daily_summary_api.py). No query params."""
        try:
            result = daily_summary_api.handle_daily_summary_request(PROMETHEUS_URL, time.time())
            body = json.dumps(result).encode()
            status = 200
        except Exception as e:
            body = json.dumps({"error": str(e)}).encode()
            status = 400
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _serve_events(self):
        """Major-event feed derived from Prometheus (hub only — see
        events_api.py): GPU/CPU temp alerts, rental slot changes, price
        changes. Query params: hours (default 24), limit (default 60),
        rig (optional filter)."""
        _, _, qs = self.path.partition("?")
        query = urllib.parse.parse_qs(qs)
        try:
            result = events_api.handle_events_request(PROMETHEUS_URL, query, time.time())
            body = json.dumps(result).encode()
            status = 200
        except Exception as e:
            body = json.dumps({"error": str(e)}).encode()
            status = 400
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _serve_history_rigs(self):
        """Real `rig` label values from Prometheus, for the History page's
        filter dropdown — NOT the display names from /api/config (see
        history_api.list_rigs's docstring for why those can diverge)."""
        try:
            rigs = history_api.list_rigs(PROMETHEUS_URL)
            body = json.dumps({"rigs": rigs}).encode()
            status = 200
        except Exception as e:
            body = json.dumps({"error": str(e), "rigs": []}).encode()
            status = 400
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _serve_history(self):
        """Paginated historical query against the central Prometheus (hub
        only — see history_api.py). Query params: metric (required, from an
        allow-list), rig, machine_id, gpu_idx, hours (window size, default
        24), page (0 = most recent window, 1 = one window further back...),
        points (target sample count, default 200)."""
        path_only, _, qs = self.path.partition("?")
        query = urllib.parse.parse_qs(qs)
        try:
            result = history_api.handle_history_request(PROMETHEUS_URL, query, time.time())
            status = 200 if "error" not in result else 400
        except Exception as e:
            result = {"error": str(e)}
            status = 400
        body = json.dumps(result).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _serve_diag(self):
        """Read-only host diagnostics (GPU/CPU/network/kaalia-log) for THIS
        rig only — see assistant.py. Same no-auth posture as /api/data."""
        path_only, _, qs = self.path.partition("?")
        kind = path_only[len("/api/diag/"):].strip("/")
        query = urllib.parse.parse_qs(qs)
        try:
            result = assistant.handle_diag_request(kind, query)
        except Exception as e:
            result = {"error": str(e)}
        body = json.dumps(result).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _serve_chat(self):
        """Server-side OpenAI tool-use loop — the OPENAI_API_KEY never
        leaves this process (see assistant.py). Rate-limited since this
        endpoint costs real money per call and, like the rest of this
        dashboard, has no auth in front of it."""
        client_ip = self.client_address[0]
        status = 200
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length <= 0 or length > 8192:
                raise ValueError("bad request size")
            payload = json.loads(self.rfile.read(length))
            question = str(payload.get("question", "")).strip()[:500]
            context = payload.get("context", [])
            if not question:
                raise ValueError("empty question")
            if assistant.rate_limited(client_ip):
                answer = "Chat is rate-limited right now — try again in a bit."
            else:
                answer = assistant.run_chat(question, context, SELF_NAME, PEER_URLS, PEER_NAMES)
            body = json.dumps({"answer": answer}).encode()
        except Exception as e:
            status = 400
            body = json.dumps({"error": str(e)}).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _serve_peer(self):
        """Proxy /api/data from a peer rig (runs server-side, works over LAN and public).
        /api/peer -> peer index 0 (legacy path). /api/peer/N -> peer index N."""
        path_only = self.path.split("?", 1)[0]
        rest = path_only[len("/api/peer"):].strip("/")
        idx = int(rest) if rest.isdigit() else 0

        if idx >= len(PEER_URLS):
            body = json.dumps({"error": f"no peer configured at index {idx}", "events": []}).encode()
        else:
            try:
                req = urllib.request.urlopen(PEER_URLS[idx] + "/api/data", timeout=8)
                body = req.read()
            except Exception as e:
                body = json.dumps({"error": str(e), "events": [], "online": False}).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _serve_config(self):
        """Tell the frontend how many rigs exist (self + configured peers) so the
        combined dashboard builds itself dynamically. Add a rig by setting
        PEER_URLS/PEER_NAMES on this host and restarting — no frontend changes."""
        rigs = [{"name": SELF_NAME, "url": ""}]
        for i in range(len(PEER_URLS)):
            name = PEER_NAMES[i] if i < len(PEER_NAMES) else f"Rig {i+2}"
            url = "peer" if i == 0 else f"peer/{i}"
            rigs.append({"name": name, "url": url})
        body = json.dumps({"rigs": rigs, "chatEnabled": assistant.CHAT_ENABLED}).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _serve_data(self):
        try:
            events = []
            p = Path(DATA_FILE)
            if p.exists():
                # Include all events (no cutoff) so daily_earnings history shows in dashboard
                for line in p.read_text().splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        ev = json.loads(line)
                        events.append(ev)
                    except Exception:
                        pass
            body = json.dumps({"host": socket.gethostname(), "events": events}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except BrokenPipeError:
            pass
        except Exception as e:
            try: self.send_error(500, str(e))
            except BrokenPipeError: pass

    def _serve_file(self, path, mime):
        try:
            data = path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except BrokenPipeError:
            pass
        except Exception:
            try: self.send_error(404)
            except BrokenPipeError: pass

    def log_message(self, *_):
        pass

    def handle_error(self, request, client_address):
        pass  # suppress BrokenPipeError and connection reset noise

if __name__ == "__main__":
    srv = http.server.HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[gpu-dashboard] http://localhost:{PORT}  (data: {DATA_FILE})")
    srv.serve_forever()
