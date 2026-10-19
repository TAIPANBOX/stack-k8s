# The measured checks for the stack-k8s v1.5.0 door (CLAUDE.md invariant 54, 62, 63). Run by run-v1.19.0.sh
# against port-forwards to vouchryx, the gateway, the broker and wardryx. Each line prints the HTTP status and
# the refusal reason the service gave; a check that does not match its expected status counts as a failure.
# The DPoP proof code is the one evidence/agent-tokens-kind/dpop.py uses (K2), imported, not copied.
import base64, hashlib, json, os, sys, time, urllib.error, urllib.parse, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "agent-tokens-kind"))
import dpop  # noqa: E402

VX = "http://127.0.0.1:24310"
GW = "http://127.0.0.1:24400"
BR = "http://127.0.0.1:24420"
WD = "http://127.0.0.1:24430"
AUD = "https://vouchryx.agent-stack.invalid"
GW_HTU = "http://tokenfuse-gateway:4100/v1/messages"
BR_HTU = "http://tokenfuse-mcp-broker:4200/mcp"
OPERATOR = "agent://tails.example/agents/operator"
OTHER = "agent://tails.example/agents/other"
BODY = json.dumps({"model": "stub", "max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]}).encode()
W = sys.argv[1] if len(sys.argv) > 1 else "."
fails = 0


def b64u_sha(s):
    return dpop.b64u(hashlib.sha256(s.encode()).digest())


def send(url, body=None, headers=None, method="POST", timeout=20):
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception as e:  # a call that never answers is a failed check, with the time it took
        return 0, "no answer after %.0f s: %s" % (time.time() - t0, e)


def reason(txt):
    try:
        j = json.loads(txt)
    except Exception:
        return txt[:60].replace("\n", " ")
    err = j.get("error", j)
    if isinstance(err, dict):
        return str(err.get("reason") or err.get("type") or err.get("code") or err.get("message", ""))[:70]
    return str(err)[:70]


def check(label, want, got_status, txt):
    global fails
    ok = got_status == want
    if not ok:
        fails += 1
    print(f"{'ok  ' if ok else 'FAIL'} {label:<60} HTTP {got_status} (want {want})  {reason(txt)}")


def token(key, agent_id, secret, resource=AUD):
    body = {"grant_type": "client_credentials"}
    if resource is not None:
        body["resource"] = resource
    basic = "Basic " + base64.b64encode((urllib.parse.quote(agent_id, safe="") + ":" + urllib.parse.quote(secret, safe="")).encode()).decode()
    proof = dpop.proof(key, "POST", "http://vouchryx:4310/v1/token")
    return send(VX + "/v1/token", body=urllib.parse.urlencode(body).encode(),
                headers={"content-type": "application/x-www-form-urlencoded", "DPoP": proof, "Authorization": basic})


def gw_call(label, want, headers):
    h = {"content-type": "application/json", "anthropic-version": "2023-06-01", "x-fuse-run-id": "run-" + os.urandom(6).hex()}
    h.update(headers)
    st, txt = send(GW + "/v1/messages", body=BODY, headers=h)
    check(label, want, st, txt)
    return st, txt


secret = open(os.path.join(W, "operator.secret")).read().strip()
key = dpop.Key(os.path.join(W, "dpop-operator.pem"))
other_key = dpop.Key(os.path.join(W, "dpop-stranger.pem"))
static = {k: open(os.path.join(W, k + ".secret")).read().strip() for k in ("felyx", "stranger")}

print("== vouchryx: the token service, agents-only (invariants 24 and 54)")
st, body = token(key, OPERATOR, secret)
check("enrolled operator agent asks for its token, resource = the one audience", 200, st, json.dumps(body) if isinstance(body, dict) else body)
tok = json.loads(body)["access_token"] if st == 200 else ""
st2, body2 = token(key, OPERATOR, secret, resource="https://vouchryx.other.invalid")
check("the same agent asks for another audience", 400, st2, body2)
st3, body3 = token(key, OPERATOR, "not-the-secret")
check("a wrong enrolment secret is refused", 401, st3, body3)

print("== gateway: agent tokens are required (invariant 54)")
gw_call("agent token and its proof, through the gateway", 200,
        {"Authorization": "DPoP " + tok, "DPoP": dpop.proof(key, "POST", GW_HTU, ath=b64u_sha(tok))})
gw_call("a token with a stranger's proof", 401,
        {"Authorization": "DPoP " + tok, "DPoP": dpop.proof(other_key, "POST", GW_HTU, ath=b64u_sha(tok))})
gw_call("a token with no proof at all", 401, {"Authorization": "DPoP " + tok})
gw_call("a token beside a static key", 401,
        {"Authorization": "DPoP " + tok, "DPoP": dpop.proof(key, "POST", GW_HTU, ath=b64u_sha(tok)), "x-fuse-key": static["felyx"]})
gw_call("a header naming another agent beside the token", 403,
        {"Authorization": "DPoP " + tok, "DPoP": dpop.proof(key, "POST", GW_HTU, ath=b64u_sha(tok)), "x-fuse-agent-id": OTHER})
gw_call("a static key that is on the list (felyx)", 200, {"x-fuse-key": static["felyx"], "x-fuse-agent-id": "agent://tails.example/genaryx/felyx"})
gw_call("a static key that is NOT on the list (stranger)", 401, {"x-fuse-key": static["stranger"], "x-fuse-agent-id": "agent://tails.example/agents/stranger"})

print("== broker: the same token at the second door (invariant 54)")
bproof = dpop.proof(key, "POST", BR_HTU, ath=b64u_sha(tok))
bbody = json.dumps({"jsonrpc": "2.0", "id": 7, "method": "tools/call",
                    "params": {"name": "lookup", "arguments": {"order": "A1"}}}).encode()
st, txt = send(BR + "/mcp", body=bbody, timeout=60, headers={"content-type": "application/json", "accept": "application/json, text/event-stream",
                                                 "MCP-Protocol-Version": "2025-06-18", "x-fuse-run-id": "run-broker-" + os.urandom(4).hex(),
                                                 "Authorization": "DPoP " + tok, "DPoP": bproof})
check("agent token and its proof, through the broker (its tool-call check answers)", 200, st, txt)
st, txt = send(BR + "/mcp", body=bbody, timeout=60, headers={"content-type": "application/json", "accept": "application/json, text/event-stream",
                                                 "MCP-Protocol-Version": "2025-06-18", "x-fuse-run-id": "run-broker-" + os.urandom(4).hex(),
                                                 "Authorization": "DPoP " + tok, "DPoP": dpop.proof(other_key, "POST", BR_HTU, ath=b64u_sha(tok))})
check("a stranger's proof at the broker", 401, st, txt)

print("== wardryx: decides from the agent's token, not the enforcement point's word (invariant 63)")
pep = open(os.path.join(W, "wardryx.pep")).read().strip()
decide = {"run_id": "run-w-1", "tool_names": ["lookup"], "identity_source": "agent-token"}
st, txt = send(WD + "/v1/decide", body=json.dumps(dict(decide, agent_id=OPERATOR, agent_token=tok, agent_dpop_proof=dpop.proof(key, "POST", GW_HTU, ath=b64u_sha(tok)))).encode(),
               headers={"content-type": "application/json", "Authorization": "Bearer " + pep})
check("the agent's own token and proof, asserted agent = the token's subject", 200, st, txt)
st, txt = send(WD + "/v1/decide", body=json.dumps(dict(decide, agent_id=OTHER, agent_token=tok, agent_dpop_proof=dpop.proof(key, "POST", GW_HTU, ath=b64u_sha(tok)))).encode(),
               headers={"content-type": "application/json", "Authorization": "Bearer " + pep})
check("asserted agent contradicts the token (the token says another agent)", 403, st, txt)
st, txt = send(WD + "/v1/decide", body=json.dumps(dict(decide, agent_id=OPERATOR, agent_token=tok,
                                                       agent_dpop_proof=dpop.proof(other_key, "POST", GW_HTU, ath=b64u_sha(tok)))).encode(),
               headers={"content-type": "application/json", "Authorization": "Bearer " + pep})
check("a proof from another key", 403, st, txt)

print(f"== {'all checks as expected' if fails == 0 else str(fails) + ' check(s) not as expected'}")
sys.exit(1 if fails else 0)
