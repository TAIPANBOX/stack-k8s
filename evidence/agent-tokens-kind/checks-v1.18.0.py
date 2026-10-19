# The checks of the v1.2.0 pin set, run from the scratch directory (the files the helpers read live
# there: enrol.secret, gw-client.secret, revoke.key, dpop-agent.pem). Prints one line per check.
import base64, io, json, contextlib, sys, time, urllib.error
import dpop, request, calls, broker_call

def claims(tok):
    payload = tok.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))

key = dpop.Key("dpop-agent.pem")
fails = []

# 1. an agent asks for its token with the new audience (RFC 8707 resource)
st, body = request.enrolled(key)
if st == 200:
    c = claims(body["access_token"])
    print(f"1 admitted: resource=AUD -> HTTP {st}; aud={c.get('aud')} iss={c.get('iss')} sub={c.get('sub')}")
    if c.get("aud") != request.AUD:
        fails.append("the token's aud is not the audience asked for")
else:
    print(f"1 admitted: resource=AUD -> HTTP {st} {body}")
    fails.append("the enrolled agent did not get a token with the new audience")
    sys.exit(1)
tok = body["access_token"]
open("token-enrolled.txt", "w").write(tok)

# 2. an agent that names no audience
st2, body2 = request.enrolled(key, resource=None)
err = body2.get("error") if isinstance(body2, dict) else body2
desc = body2.get("error_description", "") if isinstance(body2, dict) else ""
print(f"2 no audience named -> HTTP {st2} {json.dumps(body2)[:300]}")
if st2 == 200 or err != "invalid_target":
    fails.append("a request that names no audience was not refused")
# the reason (audience_not_allowed) is not in the HTTP body; the run reads it from vouchryx's event journal

# 3. the gateway door: the agent token with the new audience
with contextlib.redirect_stdout(io.StringIO()) as buf:
    s3 = calls.call({}, key=key, token=tok, label="3 gateway door, agent token")
print("3 gateway door, agent token -> HTTP", s3)
if s3 != 200:
    fails.append("the gateway did not admit the agent token")

# 4. the broker door: the same token, relayed to the MCP upstream
s4, b4 = broker_call.call(tok, key, "run-broker-1")
print(f"4 broker door, agent token -> HTTP {s4} {b4[:160]}")
if s4 != 200:
    fails.append("the broker did not admit the agent token")

# 5. a stop reaches the gateway within one poll (ban; the gateway polls its revocation list every 12 s)
import urllib.request
REVOKE = open("revoke.key").read().strip()
SUBJ = "agent://k2.example/agents/enrolled-agent"
def vx(path, body):
    req = urllib.request.Request("http://127.0.0.1:24310" + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"content-type": "application/json", "Authorization": "Bearer " + REVOKE})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status
    except urllib.error.HTTPError as e:
        if path == "/v1/revoke/lift" and e.code == 400:   # subject_not_banned: the first trial has nothing to lift
            return e.code
        raise
N = int(sys.argv[1]) if len(sys.argv) > 1 else 3
times = []
for trial in range(1, N + 1):
    vx("/v1/revoke/lift", {"subject": SUBJ, "actor": "stack-k8s-pins", "reason": "trial %d" % trial})
    time.sleep(1.2)
    st, body = request.enrolled(key)
    assert st == 200, body
    t = body["access_token"]
    time.sleep(1.2)
    with contextlib.redirect_stdout(io.StringIO()):
        assert calls.call({}, key=key, token=t, label="pre") == 200
    t0 = time.monotonic()
    vx("/v1/revoke", {"subject": SUBJ, "ban": True, "reason": "trial %d" % trial, "actor": "stack-k8s-pins", "expires_in_seconds": 3600})
    while True:
        with contextlib.redirect_stdout(io.StringIO()):
            s = calls.call({}, key=key, token=t, label="poll")
        if s != 200 or time.monotonic() - t0 > 60:
            break
        time.sleep(0.25)
    dt = time.monotonic() - t0
    times.append(dt)
    print(f"5 ban trial {trial}: refused after {dt:.2f} s (HTTP {s})")
    if s == 200:
        fails.append("a banned agent was still admitted")
print("5 ban: %d trials, min %.2f max %.2f s (the gateway polls every 12 s)" % (N, min(times), max(times)))
if max(times) > 13:
    fails.append("a ban took longer than one poll")

print("RESULT:", "PASS" if not fails else "FAIL: " + "; ".join(fails))
sys.exit(1 if fails else 0)
