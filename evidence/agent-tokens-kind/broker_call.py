import json, sys, urllib.request, urllib.error
import dpop, request
BROKER = "http://127.0.0.1:14420"
BROKER_HTU = "http://tokenfuse-mcp-broker:4200/mcp"
def call(token, key, run, name="lookup", args=None):
    body = json.dumps({"jsonrpc": "2.0", "id": 7, "method": "tools/call",
                       "params": {"name": name, "arguments": args or {"order": "A1"}}}).encode()
    import hashlib
    h = {"content-type": "application/json", "accept": "application/json, text/event-stream",
         "MCP-Protocol-Version": "2025-06-18", "x-fuse-run-id": run,
         "Authorization": "DPoP " + token,
         "DPoP": dpop.proof(key, "POST", BROKER_HTU, ath=dpop.b64u(hashlib.sha256(token.encode()).digest()))}
    req = urllib.request.Request(BROKER + "/mcp", data=body, method="POST", headers=h)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
if __name__ == "__main__":
    key = dpop.Key("dpop-agent.pem")
    st, body = request.enrolled(key)
    tok = body["access_token"]
    for label, run in [("broker call by agent token", "run-broker-1")]:
        s, b = call(tok, key, run)
        print(label, "-> HTTP", s, b[:300])
