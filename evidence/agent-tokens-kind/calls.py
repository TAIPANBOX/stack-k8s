import base64, hashlib, json, sys, time, urllib.request, urllib.error
import dpop, request
GW = "http://127.0.0.1:14400"
GW_HTU = "http://tokenfuse-gateway:4100/v1/messages"
BODY = json.dumps({"model": "stub", "max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]}).encode()

def ath(token):
    return dpop.b64u(hashlib.sha256(token.encode()).digest())

def call(headers, key=None, token=None, proof_key=None, label=""):
    h = {"content-type": "application/json", "anthropic-version": "2023-06-01", "x-fuse-run-id": "run-" + label.replace(" ", "-")}
    h.update(headers)
    if token:
        pk = proof_key or key
        h["Authorization"] = "DPoP " + token
        h["DPoP"] = dpop.proof(pk, "POST", GW_HTU, ath=ath(token))
    req = urllib.request.Request(GW + "/v1/messages", data=BODY, method="POST", headers=h)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            st, txt = r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        st, txt = e.code, e.read().decode()
    try:
        j = json.loads(txt); reason = j.get("error", {}).get("reason") or j.get("error", {}).get("type") or ("ok" if st == 200 else "")
    except Exception:
        reason = txt[:80]
    print(f"{label:<44} HTTP {st}  {reason}")
    return st

if __name__ == "__main__":
    key = dpop.Key("dpop-agent.pem")
    st, body = request.enrolled(key)
    assert st == 200, body
    tok = body["access_token"]
    open("token-enrolled.txt", "w").write(tok)
    client = open("gw-client.secret").read().strip()
    call({}, key=key, token=tok, label="1 agent token + its proof")
    call({"x-fuse-agent-id": "agent://k2.example/agents/someone-else"}, key=key, token=tok, label="2 header names another agent")
    call({"x-fuse-key": client}, key=key, token=tok, label="3 token beside a static key")
    call({"x-fuse-key": client}, label="4 static key alone (accept coexists)")
    call({}, key=key, token=tok, proof_key=dpop.Key("dpop-other.pem"), label="5 token with a stranger's proof")
    call({}, token="notavalidtoken", key=key, label="6 forged token")
    call({}, label="7 no credential at all")
