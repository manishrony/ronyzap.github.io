#!/usr/bin/env python3
"""GPU Monitor dashboard server — serves UI + /api/data from JSONL log."""
import http.server, json, os, socket
from datetime import datetime, timedelta, timezone
from pathlib import Path

DATA_FILE = os.environ.get("GPU_DATA", "/var/log/gpu_monitor_data.jsonl")
PORT      = int(os.environ.get("DASHBOARD_PORT", "8080"))
DASH_DIR  = Path(__file__).parent

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/api/data"):
            self._serve_data()
        elif self.path in ("/", "/index.html"):
            self._serve_file(DASH_DIR / "index.html", "text/html; charset=utf-8")
        elif self.path in ("/combined", "/combined.html"):
            self._serve_file(DASH_DIR / "combined.html", "text/html; charset=utf-8")
        else:
            self.send_error(404)

    def _serve_data(self):
        try:
            events = []
            p = Path(DATA_FILE)
            if p.exists():
                cutoff = (datetime.now(timezone.utc) - timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
                for line in p.read_text().splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        ev = json.loads(line)
                        if ev.get("ts", "") >= cutoff:
                            events.append(ev)
                    except Exception:
                        pass
            body = json.dumps({"host": socket.gethostname(), "events": events}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception as e:
            self.send_error(500, str(e))

    def _serve_file(self, path, mime):
        try:
            data = path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception:
            self.send_error(404)

    def log_message(self, *_):
        pass  # suppress access logs

if __name__ == "__main__":
    srv = http.server.HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[gpu-dashboard] http://localhost:{PORT}  (data: {DATA_FILE})")
    srv.serve_forever()
