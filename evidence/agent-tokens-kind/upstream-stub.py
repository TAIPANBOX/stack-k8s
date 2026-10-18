# Stands in for the provider: answers POST /v1/messages and records (never prints) whether the
# x-api-key it received equals the key file mounted beside it.
import http.server, json, os
KEY = open("/run/upstream/anthropic_key").read().strip()
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); self.rfile.read(n)
        got = self.headers.get("x-api-key", "")
        line = json.dumps({"path": self.path, "upstream_saw_provider_key": got == KEY})
        print("upstream: " + line, flush=True)
        body = json.dumps({"id": "msg_stub", "type": "message", "role": "assistant", "content": [{"type": "text", "text": "ok"}], "model": "stub", "usage": {"input_tokens": 1, "output_tokens": 1}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("0.0.0.0", 18080), H).serve_forever()
