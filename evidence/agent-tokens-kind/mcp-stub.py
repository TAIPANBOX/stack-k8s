# Stands in for the MCP upstream the broker relays to: answers initialize, tools/list and tools/call.
import http.server, json
TOOLS = [{"name": "lookup", "description": "look up an order", "inputSchema": {"type": "object", "properties": {"order": {"type": "string"}}}}]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); req = json.loads(self.rfile.read(n) or b"{}")
        m = req.get("method", ""); rid = req.get("id")
        if m == "initialize":
            res = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "mcp-stub", "version": "0"}}
        elif m == "tools/list":
            res = {"tools": TOOLS}
        elif m == "tools/call":
            res = {"content": [{"type": "text", "text": "stub answered " + str((req.get("params") or {}).get("name", ""))}], "isError": False}
        else:
            res = None
        body = json.dumps({"jsonrpc": "2.0", "id": rid, "result": res} if res is not None else {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "no such method"}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("0.0.0.0", 4320), H).serve_forever()
