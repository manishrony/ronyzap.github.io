#!/usr/bin/env python3
"""GPU Monitor dashboard server — serves UI + /api/data from JSONL log."""
import http.server, json, os, socket, urllib.request, urllib.error
from pathlib import Path

DATA_FILE = os.environ.get("GPU_DATA", "/var/log/gpu_monitor_data.jsonl")
PORT      = int(os.environ.get("DASHBOARD_PORT", "8080"))
DASH_DIR  = Path(__file__).parent

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
        if self.path.startswith("/api/data"):
            self._serve_data()
        elif self.path.startswith("/api/config"):
            self._serve_config()
        elif self.path.startswith("/api/peer"):
            self._serve_peer()
        elif self.path in ("/", "/index.html"):
            self._serve_file(DASH_DIR / "index.html", "text/html; charset=utf-8")
        elif self.path in ("/combined", "/combined.html"):
            self._serve_file(DASH_DIR / "combined.html", "text/html; charset=utf-8")
        elif self.path in ("/market", "/market.html"):
            self._serve_file(DASH_DIR / "market.html", "text/html; charset=utf-8")
        else:
            self.send_error(404)

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
        body = json.dumps({"rigs": rigs}).encode()
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
