import io, contextlib, json, time, urllib.request, urllib.error, sys
import dpop, request, calls
REVOKE = open("revoke.key").read().strip()
SUBJ = "agent://k2.example/agents/enrolled-agent"
key = dpop.Key("dpop-agent.pem")
def vx(path, body):
    req = urllib.request.Request("http://127.0.0.1:14310" + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"content-type": "application/json", "Authorization": "Bearer " + REVOKE})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.status
results = []
N = int(sys.argv[1])
for trial in range(1, N + 1):
    vx("/v1/revoke/lift", {"subject": SUBJ, "actor": "k2-e2e", "reason": "trial %d" % trial})
    time.sleep(1.2)
    st, body = request.enrolled(key)
    assert st == 200, body
    tok = body["access_token"]
    time.sleep(1.2)
    with contextlib.redirect_stdout(io.StringIO()):
        s0 = calls.call({}, key=key, token=tok, label="pre")
    assert s0 == 200, s0
    t0 = time.monotonic()
    vx("/v1/revoke", {"subject": SUBJ, "ban": True, "reason": "trial %d" % trial, "actor": "k2-e2e", "expires_in_seconds": 3600})
    polls = 0
    while True:
        polls += 1
        with contextlib.redirect_stdout(io.StringIO()):
            s = calls.call({}, key=key, token=tok, label="poll")
        if s != 200:
            break
        time.sleep(0.25)
        if time.monotonic() - t0 > 60:
            break
    dt = time.monotonic() - t0
    results.append(dt)
    print(f"trial {trial}: refused after {dt:.2f} s ({polls} polls, HTTP {s})", flush=True)
print("min %.2f  max %.2f  mean %.2f s over %d trials" % (min(results), max(results), sum(results)/len(results), len(results)))
