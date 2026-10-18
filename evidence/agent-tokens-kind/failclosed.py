import io, contextlib, json, subprocess, time, urllib.request
import dpop, request, calls
REVOKE = open("revoke.key").read().strip()
SUBJ = "agent://k2.example/agents/enrolled-agent"
key = dpop.Key("dpop-agent.pem")
client = open("gw-client.secret").read().strip()
def vx(path, body):
    req = urllib.request.Request("http://127.0.0.1:14310" + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"content-type": "application/json", "Authorization": "Bearer " + REVOKE})
    with urllib.request.urlopen(req, timeout=10) as r: return r.status
kc = lambda *a: subprocess.run(["kubectl", "--context", "kind-k2e2e", "-n", "agent-stack"] + list(a), check=True, capture_output=True, text=True).stdout
vx("/v1/revoke/lift", {"subject": SUBJ, "actor": "k2-e2e", "reason": "fail-closed test"})
time.sleep(1.2)
st, body = request.enrolled(key); tok = body["access_token"]
time.sleep(1.2)
with contextlib.redirect_stdout(io.StringIO()): s0 = calls.call({}, key=key, token=tok, label="pre")
print("before: agent token", s0)
kc("scale", "deploy/vouchryx", "--replicas=0")
t0 = time.monotonic()
kc("wait", "--for=delete", "pod", "-l", "app=vouchryx", "--timeout=60s")
print("vouchryx down at t=0")
seen = []
while time.monotonic() - t0 < 150:
    with contextlib.redirect_stdout(io.StringIO()):
        s = calls.call({}, key=key, token=tok, label="down")
        sk = calls.call({"x-fuse-key": client}, label="static")
    seen.append((round(time.monotonic() - t0, 1), s, sk))
    if s != 200:
        print(f"agent token refused at t={time.monotonic() - t0:.1f} s (HTTP {s}); static key meanwhile HTTP {sk}")
        break
    time.sleep(2)
else:
    print("agent token still admitted at 150 s")
print("last samples:", seen[-3:])
kc("scale", "deploy/vouchryx", "--replicas=1")
kc("rollout", "status", "deploy/vouchryx", "--timeout=120s")
