import base64, json, subprocess, sys, urllib.parse, urllib.request, urllib.error
import dpop
ISS = "http://vouchryx:4310"
# The one audience an agent token carries (stack-k8s v1.1.49, invariant 54, GOTCHAS 137). An agent asks for
# it as RFC 8707 `resource`; a request that names none is refused audience_not_allowed.
AUD = "https://vouchryx.agent-stack.invalid"
LOCAL = "http://127.0.0.1:24310"

def form_enc(s):
    return urllib.parse.quote(s, safe="")

def basic(agent_id, secret):
    raw = form_enc(agent_id) + ":" + form_enc(secret)
    return "Basic " + base64.b64encode(raw.encode()).decode()

def post_token(key, headers, body):
    proof = dpop.proof(key, "POST", ISS + "/v1/token")
    data = urllib.parse.urlencode(body).encode()
    req = urllib.request.Request(LOCAL + "/v1/token", data=data, method="POST")
    req.add_header("content-type", "application/x-www-form-urlencoded")
    req.add_header("DPoP", proof)
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")

def enrolled(key, resource=AUD):
    secret = open("enrol.secret").read().strip()
    body = {"grant_type": "client_credentials"}
    if resource is not None:
        body["resource"] = resource
    return post_token(key, {"Authorization": basic("agent://k2.example/agents/enrolled-agent", secret)}, body)

def workload(key, sa_token):
    return post_token(key, {}, {"grant_type": "client_credentials", "resource": AUD,
                                "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                                "client_assertion": sa_token})

if __name__ == "__main__":
    key = dpop.Key("dpop-agent.pem")
    which = sys.argv[1]
    if which == "enrolled":
        st, body = enrolled(key)
    elif which == "no-resource":
        st, body = enrolled(key, resource=None)
    else:
        tok = subprocess.run(["kubectl", "-n", "agent-stack", "create", "token", "workload-agent",
                              "--audience", ISS, "--duration", "600s"], check=True, capture_output=True, text=True).stdout.strip()
        st, body = workload(key, tok)
    print("HTTP", st, sorted(body.keys()) if isinstance(body, dict) else body)
    if isinstance(body, dict) and "error" in body:
        print("error:", body.get("error"), body.get("error_description", "")[:200])
