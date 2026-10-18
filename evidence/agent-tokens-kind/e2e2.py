import json, subprocess, time, urllib.request, urllib.error, sys
import dpop, request, calls
key = dpop.Key("dpop-agent.pem")
sa = subprocess.run(["kubectl", "--context", "kind-k2e2e", "-n", "agent-stack", "create", "token", "workload-agent",
                     "--audience", request.ISS, "--duration", "600s"], check=True, capture_output=True, text=True).stdout.strip()
st, body = request.workload(key, sa)
print("workload token issued:", st)
wt = body.get("access_token", "")
calls.call({}, key=key, token=wt, label="8 workload-agent token + its proof")
# replay: the same proof header sent twice, the second must be refused
import hashlib
p = dpop.proof(key, "POST", calls.GW_HTU, ath=calls.ath(wt))
for i, label in enumerate(["9 replayed proof, first use", "9 replayed proof, second use"]):
    h = {"content-type": "application/json", "anthropic-version": "2023-06-01", "x-fuse-run-id": "run-replay-" + str(i),
         "Authorization": "DPoP " + wt, "DPoP": p}
    req = urllib.request.Request(calls.GW + "/v1/messages", data=calls.BODY, method="POST", headers=h)
    try:
        with urllib.request.urlopen(req, timeout=10) as r: st2, t2 = r.status, r.read().decode()
    except urllib.error.HTTPError as e: st2, t2 = e.code, e.read().decode()
    print(f"{label:<44} HTTP {st2}  {t2[:70]}")
