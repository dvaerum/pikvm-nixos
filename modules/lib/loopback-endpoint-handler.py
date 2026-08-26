import hmac, json, os, subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ["PORT"])
with open(os.environ["TOKEN_FILE"], "r") as fh:
    TOKEN = fh.read().strip()

class Handler(BaseHTTPRequestHandler):
    def _send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def reply(self, code, ok, message):
        self._send_json(code, {"ok": ok, "message": message})

    def _authorized(self):
        auth = self.headers.get("Authorization", "")
        token = auth[7:] if auth.startswith("Bearer ") else ""
        return bool(token) and hmac.compare_digest(token, TOKEN)

    def log_message(self, *args):
        pass  # don't log tokens/paths
