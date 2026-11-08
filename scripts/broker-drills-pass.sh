#!/usr/bin/env bash
#
# Enforces invariant 85 of CLAUDE.md: the fire drills reach the MCP broker with a key of their own,
# every static key the broker admits is a gateway client key of the same id and secret, and
# mockryx's broker drills pass against the broker as this repository configures it.
#
# WHAT THIS IS ABOUT
#
# The broker asks the gateway's tool-call check about every tool call (TOKENFUSE_MCP_TAINT_GATEWAY,
# fail closed), and for a static key it asks with the CALLER's own key (tokenfuse invariant 118).
# A key the broker admits and the gateway does not hold is refused 401 there, and the broker
# refuses the call -32004 "the taint gate answered 401". Measured on forge 2026-11-08 with the
# images these manifests pin: the drills' broker key alone made the PII drill and both steps of
# the tool-hold drill fail on that refusal, and the typed door's own `broker-caller` was refused
# the same way on every call, which nothing had caught. So the two keys the broker admits are
# gateway keys too, one secret under one id at both doors.
#
# WHAT THIS CHECKS
#
#   A. THE WIRING, read from the files. The broker's static list names broker-caller and
#      drills-broker; the gateway's STACK_STATIC_KEY_IDS names both; lib/identity-mint.sh mints
#      both and the Secret drills-broker-key; typed/mode.sh copies both from the gateway's keys
#      into the broker's (door-secrets) and keeps a kept broker Secret in step (door-callers);
#      every launcher calls identity_mint_guard before its first apply and door-callers in its
#      typed branch; the drills-broker CronJob runs the pinned mockryx on /scenarios/mcp against
#      this broker with the key from drills-broker-key, labelled role: drills-broker, and the two
#      NetworkPolicies open exactly that pod to the broker on 4200.
#   B. THE RUN. On two docker networks with no route out, one for the stack and one for the
#      drill (the broker on both, as the NetworkPolicies have it): the wardryx 10-planes pins,
#      serving the starter policy and the block lib/tool-hold.sh writes; the gateway 10-planes
#      pins, with its literal settings and a key set in the shape lib/identity-mint.sh mints
#      (its identity map is identity_mint_map's); the broker 52 pins, with 52's literal settings
#      and the Secret `typed/mode.sh door-secrets` mints from that key set; a stand-in MCP server
#      that answers search_notes, as the broker's default upstream, and serves vouchryx's key set
#      and revocation list (a TEST FIXTURE, in no manifest); and the mockryx the drills-broker
#      CronJob pins, run with that CronJob's own arguments and environment, reading the key from
#      a root:10001 0440 file as fsGroup mounts it. It must exit 0 with mcp-secret-in-arguments
#      and mcp-ungranted-tool-held passed, and mcp-pii-in-arguments passed when 52 blocks PII and
#      skipped_not_configured when it does not. And an agent's call with broker-caller must pass
#      the tool-call check: wardryx answers it (held, when_no_grant), not the taint gate.
#   C. THE CONTROLS, so a pass is not the harness passing everything: the same run with the
#      drills-broker entry left out of the gateway's keys and list fails on the taint gate, and
#      the run with a key the broker does not hold is refused at the broker's door.
#
# WHAT THE RUN STANDS IN FOR
#
# The NetworkPolicies are read in A and stood in for by the two networks in B. The stand-in
# server is a test fixture: no MCP server in this stack answers search_notes, so on a cluster the
# tool-hold drill's second step reports a Finding (52 says so beside the CronJob). The key set is
# built here in identity-mint's shape, and scripts/metered-doors-require-keys.sh holds the mint.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No 52, no CronJob, no Docker, an image that never answered, or a mockryx report that names no
# scenario: each is reported and fails, and says it measured nothing.
#
# (teeth cases: scripts/gates-have-teeth.sh, "broker-drills-pass: ...";
#  scenarios: features/the-drills-reach-the-broker-with-a-key-of-their-own.feature)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec python3 - "$@" <<'PY'
import base64, json, os, re, secrets, string, subprocess, sys, tempfile, time

ROOT = os.getcwd()
M10 = "manifests/10-planes.yaml"
M30 = "manifests/30-network-policy.yaml"
M40 = "manifests/40-routines-and-secrets.yaml"
M52 = "manifests/52-tokenfuse-mcp-broker.yaml"
MINT = "lib/identity-mint.sh"
MODE = "typed/mode.sh"
LAUNCHERS = ["deploy.sh", "cloud/gcp/deploy-gcp.sh", "cloud/aws/deploy-aws.sh"]
CALLERS = ["broker-caller", "drills-broker"]

problems = []
def fail(msg):
    problems.append(msg)
    print("FAIL: " + msg, flush=True)

for p in [M10, M30, M40, M52, MINT, MODE] + LAUNCHERS:
    if not os.path.isfile(p):
        print(f"FAIL: {p} is not there, so this measured NOTHING about the broker drills.")
        sys.exit(1)

def docs(path):
    return [d for d in re.split(r"(?m)^---\s*$", open(path).read()) if d.strip()]

def code(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))

def doc_named(path, kind, name):
    for d in docs(path):
        if re.search(rf"(?m)^kind:\s*{kind}\s*$", d) and re.search(rf"(?m)^  name:\s*{re.escape(name)}\s*$", d):
            return code(d)
    return None

def container(doc, name):
    """The lines of one container of a pod template, by its name."""
    lines = doc.split("\n")
    for i, l in enumerate(lines):
        m = re.match(r"^(\s*)- name:\s*(\S+)\s*$", l)
        if m and m.group(2) == name:
            ind = len(m.group(1))
            out = [l]
            for k in lines[i + 1:]:
                if k.strip() and len(k) - len(k.lstrip()) <= ind:
                    break
                out.append(k)
            return "\n".join(out)
    return None

def literal_env(block):
    env = {}
    for k, v in re.findall(r'(?m)^\s*- \{\s*name:\s*([A-Z_0-9]+)\s*,\s*value:\s*"([^"]*)"\s*\}', block or ""):
        env[k] = v
    return env

def image_of(block):
    m = re.search(r"(?m)^\s*image:\s*(\S+)\s*$", block or "")
    return m.group(1) if m else None

# ---- A. the wiring ---------------------------------------------------------------------
broker_doc = doc_named(M52, "Deployment", "tokenfuse-mcp-broker")
gw_doc = doc_named(M10, "Deployment", "tokenfuse-gateway")
wx_doc = doc_named(M10, "Deployment", "wardryx")
cron = doc_named(M52, "CronJob", "drills-broker")
if broker_doc is None or gw_doc is None or wx_doc is None:
    print("FAIL: the broker, the gateway or wardryx is not where this reads it, so this measured NOTHING.")
    sys.exit(1)
broker = container(broker_doc, "broker")
gateway = container(gw_doc, "gateway")
benv, genv = literal_env(broker), literal_env(gateway)

blist = [s for s in benv.get("TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS", "").split(",") if s]
glist = [s for s in genv.get("STACK_STATIC_KEY_IDS", "").split(",") if s]
for cid in CALLERS:
    if cid not in blist:
        fail(f"A: the broker's static list {blist} does not name {cid}, so the broker refuses it under require")
    if cid not in glist:
        fail(f"A: the gateway's STACK_STATIC_KEY_IDS {glist} does not name {cid}: the broker asks the gateway's tool-call check with that key, and an unlisted key is refused there, so every call with it is refused closed")
if not benv.get("TOKENFUSE_MCP_TAINT_GATEWAY"):
    fail("A: 52's broker names no TOKENFUSE_MCP_TAINT_GATEWAY; this gate is about the check it asks, so the run below would prove nothing")

mint = code(open(MINT).read())
for needle, why in (
    (":drills-broker", "mint the drills-broker gateway key"),
    (":broker-caller", "mint the broker-caller gateway key"),
    ("IDM_DBROKER_SECRET=drills-broker-key", "keep the drills' broker key in the Secret drills-broker-key"),
    ('"key_id":"drills-broker","unit":"drills","agents":["agent://mockryx.local/*"]', "bind drills-broker to agent://mockryx.local/* in unit drills"),
    ('"key_id":"broker-caller","unit":"broker","agents":["agent://%s/typed-broker"]', "bind broker-caller to exactly agent://<td>/typed-broker in unit broker"),
    ("identity_mint_guard()", "define the guard that stops a run on the operator's keys before the first apply"),
):
    if needle not in mint:
        fail(f"A: {MINT} does not {why}")
mode_text = code(open(MODE).read())
if 'DOOR_DRILLS_ID="drills-broker"' not in mode_text or "door_gateway_callers" not in mode_text or "door_callers()" not in mode_text:
    fail(f"A: {MODE} does not copy the broker's static callers from the gateway's keys (door-secrets) and keep a kept broker Secret in step (door-callers)")

for p in LAUNCHERS:
    lines = open(p).read().split("\n")
    live = [(i, l) for i, l in enumerate(lines) if not l.lstrip().startswith("#")]
    guard = [i for i, l in live if re.match(r"^identity_mint_guard\b", l)]
    apply_ = [i for i, l in live if re.search(r'k_ "apply -k ', l)]
    callers = [i for i, l in live if re.search(r'typed/mode\.sh"?\s+door-callers\b', l)]
    render = [i for i, l in live if re.search(r'typed/mode\.sh"?\s+render\b', l)]
    if not guard or not apply_ or guard[0] > apply_[0]:
        fail(f"A: {p} does not call identity_mint_guard before its first apply, so a cluster on the operator's keys learns of the missing keys from a gateway that will not start")
    if not callers or not render or callers[0] > render[0]:
        fail(f"A: {p} does not call typed/mode.sh door-callers in its typed branch before the render")
    elif not any("patch secret tokenfuse-mcp-broker-keys --type merge --patch-file /dev/stdin" in lines[i] for i in range(callers[0], callers[0] + 8)):
        fail(f"A: {p} does not hand door-callers' patch to `patch --patch-file /dev/stdin`")

if cron is None:
    fail("A: 52 has no CronJob drills-broker, so the broker drills have nothing to run in and the drills below measure NOTHING")
    cron = ""
mx = container(cron, "mockryx")
menv = literal_env(mx)
mimage = image_of(mx)
margs = re.search(r"(?m)^\s*args:\s*\[(.*)\]\s*$", mx or "")
margs = [a.strip().strip('"') for a in margs.group(1).split(",")] if margs else []
if not mimage or not re.match(r"^ghcr\.io/taipanbox/mockryx:v(\d+)\.(\d+)\.\d+@sha256:[0-9a-f]{64}$", mimage):
    fail(f"A: the drills-broker CronJob runs {mimage!r}, not a mockryx pinned by tag and digest")
elif tuple(int(x) for x in re.match(r".*:v(\d+)\.(\d+)", mimage).groups()) < (0, 5):
    fail(f"A: the drills-broker CronJob runs {mimage}, older than v0.5.0, which has no broker key")
d40 = doc_named(M40, "CronJob", "drills")
if d40 is None or image_of(container(d40, "mockryx")) != mimage:
    fail("A: the drills CronJob and the drills-broker CronJob do not run the same mockryx")
if not margs or margs[-1] != "/scenarios/mcp" or margs[0] != "run":
    fail(f"A: the drills-broker CronJob runs {margs}, not `run ... /scenarios/mcp`")
if menv.get("MOCKRYX_MCP_BROKER") != "http://tokenfuse-mcp-broker:4200/mcp":
    fail(f"A: the drills-broker CronJob names the broker {menv.get('MOCKRYX_MCP_BROKER')!r}, not http://tokenfuse-mcp-broker:4200/mcp")
kpath = menv.get("MOCKRYX_MCP_BROKER_KEY_FILE", "")
vol = re.search(r"(?m)^\s*- name:\s*(\S+)\s*\n\s*secret:\s*\{\s*secretName:\s*drills-broker-key\s*,(.*)$", cron)
mount = None
if vol:
    m = re.search(rf"(?m)^\s*- \{{\s*name:\s*{re.escape(vol.group(1))}\s*,\s*mountPath:\s*(\S+?)\s*,\s*readOnly:\s*true\s*\}}", mx or "")
    item = re.search(r"items:\s*\[\{\s*key:\s*broker_key\s*,\s*path:\s*([^\s}]+)\s*\}\]", vol.group(2))
    if m and item:
        mount = m.group(1).rstrip("/") + "/" + item.group(1)
    if "defaultMode: 0440" not in vol.group(2):
        fail("A: the drills-broker key is not mounted at 0440, the mode fsGroup makes readable and mockryx's owner rule accepts")
if not kpath or kpath != mount:
    fail(f"A: MOCKRYX_MCP_BROKER_KEY_FILE is {kpath!r} and the key of drills-broker-key is mounted at {mount!r}; mockryx would read no key")
if not re.search(r"(?m)^\s*labels:\s*\{\s*role:\s*drills-broker\s*\}\s*$", cron):
    fail("A: the drills-broker pod is not labelled role: drills-broker, the label the two NetworkPolicies select on")
if not re.search(r"(?m)^\s*securityContext:\s*\{[^}]*fsGroup:\s*10001", cron):
    fail("A: the drills-broker pod sets no fsGroup 10001, so its 0440 key is unreadable to the drill's own user")

def np_rules():
    out = {}
    for path in sorted(os.listdir("manifests")):
        if not path.endswith(".yaml"):
            continue
        for d in docs(os.path.join("manifests", path)):
            if re.search(r"(?m)^kind:\s*NetworkPolicy\s*$", d):
                n = re.search(r"(?m)^  name:\s*(\S+)", d)
                out[n.group(1) if n else "?"] = code(d)
    return out
nps = np_rules()
eg = nps.get("drills-broker-egress", "")
ig = nps.get("broker-ingress-drills", "")
if not (re.search(r"podSelector:\s*\{\s*matchLabels:\s*\{\s*role:\s*drills-broker\s*\}\s*\}", eg) and '"Egress"' in eg
        and re.search(r"app:\s*tokenfuse-mcp-broker", eg) and re.findall(r"port:\s*(\d+)", eg) == ["4200"]):
    fail("A: drills-broker-egress does not let the drills-broker pod out to the broker on 4200 and nowhere else")
if not (re.search(r"podSelector:\s*\{\s*matchLabels:\s*\{\s*app:\s*tokenfuse-mcp-broker\s*\}\s*\}", ig) and '"Ingress"' in ig
        and re.search(r"role:\s*drills-broker", ig) and re.findall(r"port:\s*(\d+)", ig) == ["4200"]):
    fail("A: broker-ingress-drills does not admit the drills-broker pod to the broker on 4200 alone")
wider = [n for n, d in nps.items() if re.search(r"\brole:\s*drills-broker\s*\}", d) and n not in ("drills-broker-egress", "broker-ingress-drills")]
if wider:
    fail(f"A: {wider} also name the drills-broker pod, which reaches the broker and nothing else")
if re.search(r"\brole:\s*drills\s*\}", ig):
    fail("A: the broker admits the gateway drills' pod (role: drills), which holds the gateway's client key")

# The scenarios and the cases, bound both ways: every case a scenario names exists, and every case of this
# gate is named by a scenario.
FEATURE = "features/the-drills-reach-the-broker-with-a-key-of-their-own.feature"
TEETH = "scripts/gates-have-teeth.sh"
if not os.path.isfile(FEATURE) or not os.path.isfile(TEETH):
    fail(f"A: {FEATURE} or {TEETH} is not there, so the scenarios are bound to nothing")
else:
    named = set(re.findall(r'(?m)^\s*# -> gates-have-teeth\.sh "([^"]+)"\s*$', open(FEATURE).read()))
    cases = set(re.findall(r'(?m)^run_case "([^"]+)"', open(TEETH).read()))
    if not named:
        fail(f"A: {FEATURE} binds no scenario to a case, so it measured NOTHING")
    for n in sorted(named - cases):
        fail(f"A: {FEATURE} names the case {n!r}, which scripts/gates-have-teeth.sh does not run")
    for n in sorted(c for c in cases if c.startswith("broker-drills-pass: ") and c not in named):
        fail(f"A: the case {n!r} is named by no scenario in {FEATURE}")
    for chunk in re.split(r"(?m)^  Scenario:", open(FEATURE).read())[1:]:
        if "# -> gates-have-teeth.sh" not in chunk:
            fail(f"A: a scenario is bound to nothing: {chunk.strip().splitlines()[0]}")

# The drills run only on a CronJob that says how; the broker-caller probe runs whatever A found, so a
# broker that refuses the typed door's own key at the tool-call check is shown failing, not only described.
can_drill = bool(mx) and bool(mimage) and bool(margs) and bool(kpath) and kpath == mount

# ---- B and C. the run ----------------------------------------------------------------------
def sh(*args, check=False, **kw):
    return subprocess.run(list(args), capture_output=True, text=True, **kw)

if sh("docker", "version", "--format", "{{.Server.Version}}").returncode != 0:
    print("FAIL: no Docker here, so the drills were not run against the broker and this measured NOTHING.")
    sys.exit(1)

TF = image_of(broker)
GW = image_of(gateway)
WX = image_of(container(wx_doc, "wardryx"))
BB = re.search(r"(?m)^\s*image:\s*(busybox@sha256:[0-9a-f]{64})\s*$", open(M10).read())
BB = BB.group(1) if BB else None
# The stand-in server's interpreter: an upstream image pinned by digest, a test fixture named nowhere else.
PY_IMAGE = "python:3.12-alpine@sha256:e064671ca452259bab50e8e2c7bd896e39e9a343bb06ca25234adf6fe18d0fc7"
if TF != GW:
    fail(f"B: the broker runs {TF} and the gateway {GW}; they are one binary and one pin")
for img in (TF, WX, BB, PY_IMAGE) + ((mimage,) if can_drill else ()):
    if not img or (sh("docker", "image", "inspect", img).returncode != 0 and sh("docker", "pull", "-q", img).returncode != 0):
        print(f"FAIL: could not pull {img}, so the drills were not run and this measured NOTHING.")
        sys.exit(1)

# A public P-256 key with no private half anywhere: the broker and the gateway need a key set to start,
# and no token is ever minted against it.
JWKS = '{"keys":[{"kty":"EC","crv":"P-256","alg":"ES256","use":"sig","kid":"gate-unused","x":"eJ-1zzJ6ud7XA4bYAZFlayql8pKjcfFKQa72SvssoYU","y":"HysRiEKiTaopLhqxNemRKMrLya4p5aHYxRwyxjHb5o0"}]}'
STUB = r'''
import json, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
JWKS = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        port = self.server.server_address[1]
        if port == 4310 and self.path == "/.well-known/jwks.json": return self.send(200, json.loads(JWKS))
        if port == 4310 and self.path == "/v1/revocations": return self.send(200, {"as_of": int(time.time()), "revocations": []})
        self.send(404, {"error": "not here"})
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("content-length") or 0))
        sys.stderr.write("POST %s %s\n" % (self.path, raw.decode(errors="replace"))); sys.stderr.flush()
        try: req = json.loads(raw)
        except ValueError: return self.send(400, {"error": "not json"})
        rid, m = req.get("id"), req.get("method")
        if m == "tools/call" and (req.get("params") or {}).get("name") == "search_notes":
            return self.send(200, {"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": "no notes"}], "isError": False}})
        return self.send(200, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "the stand-in knows search_notes only"}})
for p in (4310, 4320):
    s = ThreadingHTTPServer(("0.0.0.0", p), H)
    threading.Thread(target=s.serve_forever, daemon=True).start()
sys.stderr.write("stand-in listening\n"); sys.stderr.flush()
while True: time.sleep(3600)
'''

ALNUM = string.ascii_letters + string.digits
def key():
    return "".join(secrets.choice(ALNUM) for _ in range(40))

tag = f"brdrill{os.getpid()}"
scratch = tempfile.mkdtemp()
made = {"ctr": [], "net": [], "vol": []}

def cleanup():
    for c in made["ctr"]:
        sh("docker", "rm", "-f", c)
    for v in made["vol"]:
        sh("docker", "volume", "rm", v)
    for n in made["net"]:
        sh("docker", "network", "rm", n)
    subprocess.run(["rm", "-rf", scratch])

def wait_log(ctr, needle, secs=40):
    end = time.time() + secs
    while time.time() < end:
        r = sh("docker", "logs", ctr)
        if needle in r.stdout + r.stderr:
            return True
        if sh("docker", "inspect", "-f", "{{.State.Running}}", ctr).stdout.strip() != "true":
            return False
        time.sleep(0.3)
    return False

def last_words(ctr):
    r = sh("docker", "logs", ctr)
    return ((r.stdout + r.stderr).strip().split("\n") or [""])[-1][-240:]

def writefile(name, text, mode=0o644):
    p = os.path.join(scratch, name)
    with open(p, "w") as f:
        f.write(text)
    os.chmod(p, mode)
    return p

def run_case(label, gw_drop=(), wrong_key=False):
    """One whole stack. Returns (mockryx exit, report or None, raw output, broker-caller answer)."""
    n_stack, n_drill = f"{tag}-{label}-stack", f"{tag}-{label}-drill"
    for n in (n_stack, n_drill):
        if sh("docker", "network", "create", "--internal", n).returncode != 0:
            raise RuntimeError(f"could not create the network {n}")
        made["net"].append(n)
    ev, kv = f"{tag}-{label}-events", f"{tag}-{label}-keys"
    for v in (ev, kv):
        sh("docker", "volume", "create", v); made["vol"].append(v)
    sh("docker", "run", "--rm", "-v", f"{ev}:/v", BB, "sh", "-c",
       "chown 0:10001 /v && chmod 2775 /v && : >/v/wardryx.ndjson && chown 65532:10001 /v/wardryx.ndjson && chmod 0640 /v/wardryx.ndjson")

    admin, pep = key(), key()
    gkeys = {i: key() for i in ("felyx", "agents", "drills", "broker", "costcrew", "drills-broker", "broker-caller")}
    spec = ",".join(f"{v}:{k}" for k, v in gkeys.items() if k not in gw_drop)
    # The broker's door Secret, as typed/mode.sh door-secrets mints it from the gateway's keys.
    full = ",".join(f"{v}:{k}" for k, v in gkeys.items())
    r = sh("bash", MODE, "door-secrets", "--with-typed", "--have", "", "--trust-domain", "acme.example",
           input="\n" + base64.b64encode(full.encode()).decode() + "\n")
    if r.returncode != 0:
        raise RuntimeError("typed/mode.sh door-secrets refused: " + r.stderr.strip()[:300])
    door = {}
    for d in re.split(r"(?m)^---\s*$", r.stdout):
        if re.search(r"(?m)^  name:\s*tokenfuse-mcp-broker-keys\s*$", d):
            for k, v in re.findall(r"(?m)^  ([A-Z_]+):\s*(\S+)\s*$", d.split("\ndata:\n", 1)[1]):
                door[k] = base64.b64decode(v).decode()
    if not door.get("TOKENFUSE_MCP_KEYS"):
        raise RuntimeError("typed/mode.sh door-secrets minted no broker Secret")

    # wardryx: the starter policy and the block, as lib/tool-hold.sh writes them for this tree.
    pol = os.path.join(scratch, f"{label}-policy"); os.makedirs(pol)
    blk = sh("bash", "-c", 'k_() { return 1; }; TRUST_DOMAIN=acme.example; ROOT="$PWD"; . lib/tool-hold.sh; tool_hold_block')
    st = sh("bash", "-c", 'k_() { return 1; }; ROOT="$PWD"; . lib/tool-hold.sh; tool_hold_starter')
    if blk.returncode != 0 or st.returncode != 0 or "when_no_grant: hold" not in blk.stdout:
        raise RuntimeError("lib/tool-hold.sh did not write the block and the starter policy")
    open(os.path.join(pol, "tool-hold.yaml"), "w").write(blk.stdout)
    open(os.path.join(pol, "policy.yaml"), "w").write(re.sub(r"(?m)^    ", "", st.stdout))
    os.chmod(pol, 0o755)
    for f in os.listdir(pol):
        os.chmod(os.path.join(pol, f), 0o644)
    c = f"{tag}-{label}-wardryx"; made["ctr"].append(c)
    sh("docker", "run", "-d", "--name", c, "--network", n_stack, "--network-alias", "wardryx", "--user", "65532:10001",
       "-e", f"WARDRYX_KEYS={admin}:default:admin,{pep}:default:pep", "-e", f"WARDRYX_APPROVAL_SECRET={key()}",
       "-v", f"{ev}:/var/lib/stack/events", "-v", f"{pol}:/etc/wardryx/policy:ro", WX,
       "serve", "-addr", "0.0.0.0:8090", "-events", "/var/lib/stack/events/wardryx.ndjson", "-policy", "/etc/wardryx/policy")
    stub = writefile(f"{label}-stub.py", STUB)
    c2 = f"{tag}-{label}-stub"; made["ctr"].append(c2)
    sh("docker", "run", "-d", "--name", c2, "--network", n_stack, "--network-alias", "typryx", "--network-alias", "vouchryx",
       "-v", f"{stub}:/stub.py:ro", PY_IMAGE, "python3", "-u", "/stub.py", JWKS)
    if not wait_log(c, "serving on") or not wait_log(c2, "stand-in listening"):
        raise RuntimeError(f"wardryx or the stand-in never answered: {last_words(c)} / {last_words(c2)}")

    jwks = writefile(f"{label}-jwks.json", JWKS)
    imap = sh("bash", "-c", 'k_() { :; }; die() { exit 1; }; . lib/identity-mint.sh; identity_mint_map acme.example').stdout
    imapf = writefile(f"{label}-identity.json", imap)
    upk = writefile(f"{label}-upstream", "sk-gate-not-a-key")
    taint = writefile(f"{label}-taint", gkeys["broker"])
    # The gateway: 10-planes' literal settings; the two lists expanded as Kubernetes expands $(VAR),
    # with the operator's own list empty, as lib/static-keys.sh creates it.
    g = dict(genv)
    g["TOKENFUSE_AGENT_TOKENS_STATIC_KEYS"] = ",".join(i for i in g.get("STACK_STATIC_KEY_IDS", "").split(",") if i and i not in gw_drop)
    g.pop("STACK_STATIC_KEY_IDS", None)
    g.update({"TOKENFUSE_CLIENT_KEYS": spec, "TOKENFUSE_IDENTITY_MAP": "/etc/tokenfuse/identity/identity.json",
              "TOKENFUSE_WARDRYX_KEY": pep, "TOKENFUSE_UPSTREAM_KEY_FILE": "/run/upstream/key"})
    genvf = writefile(f"{label}-gw.env", "".join(f"{k}={v}\n" for k, v in g.items()), 0o600)
    c3 = f"{tag}-{label}-gateway"; made["ctr"].append(c3)
    sh("docker", "run", "-d", "--name", c3, "--network", n_stack, "--network-alias", "tokenfuse-gateway", "--user", "10001:10001",
       "--env-file", genvf, "--tmpfs", "/var/lib/stack/traces:uid=10001,gid=10001",
       "-v", f"{jwks}:/etc/tokenfuse/delegation/jwks.json:ro", "-v", f"{imapf}:/etc/tokenfuse/identity/identity.json:ro",
       "-v", f"{upk}:/run/upstream/key:ro", GW)
    # The broker: 52's literal settings, the wardryx key, and the door Secret through envFrom.
    b = dict(benv)
    b["TOKENFUSE_WARDRYX_KEY"] = pep
    b.update(door)
    benvf = writefile(f"{label}-br.env", "".join(f"{k}={v}\n" for k, v in b.items()), 0o600)
    c4 = f"{tag}-{label}-broker"; made["ctr"].append(c4)
    sh("docker", "run", "-d", "--name", c4, "--network", n_stack, "--network-alias", "tokenfuse-mcp-broker", "--user", "10001:10001",
       "--env-file", benvf, "-v", f"{ev}:/var/lib/stack/events", "-v", f"{jwks}:/etc/tokenfuse/delegation/jwks.json:ro",
       "-v", f"{taint}:/run/taint/key:ro", TF, "mcp-broker")
    sh("docker", "network", "connect", "--alias", "tokenfuse-mcp-broker", n_drill, c4)
    if not wait_log(c3, "listening") or not wait_log(c4, "credential-broker listening"):
        raise RuntimeError(f"the gateway or the broker never answered: {last_words(c3)} / {last_words(c4)}")

    # mockryx: the CronJob's image, arguments and environment; its key root:10001 0440, as fsGroup mounts it.
    m = None
    report = None
    if can_drill:
        m = drill(kv, n_drill, key() if wrong_key else gkeys["drills-broker"])
        try:
            report = json.loads(m.stdout)
        except ValueError:
            pass
    # An agent's call with the typed door's own key, from the drill network: the tool-call check has to answer it.
    bc_key = ""
    for e in door["TOKENFUSE_MCP_KEYS"].split(","):
        if e.rpartition(":")[2] == "broker-caller":
            bc_key = e.rpartition(":")[0]
    probe = writefile(f"{label}-probe.py", PROBE)
    pr = sh("docker", "run", "--rm", "-i", "--network", n_drill, "-v", f"{probe}:/probe.py:ro", PY_IMAGE, "python3", "/probe.py",
            input=bc_key)
    out = (m.stdout + m.stderr) if m else ""
    secrets_seen = [v for v in list(gkeys.values()) + [bc_key] if v and v in out + pr.stdout + pr.stderr]
    return (m.returncode if m else None), report, out, pr.stdout.strip() + pr.stderr.strip()[-200:], secrets_seen

def drill(kv, n_drill, the_key):
    kdir = os.path.dirname(kpath)
    sh("docker", "run", "--rm", "-i", "-v", f"{kv}:/k", BB, "sh", "-c",
       f"cat >/k/{os.path.basename(kpath)} && chown 0:10001 /k/{os.path.basename(kpath)} && chmod 0440 /k/{os.path.basename(kpath)}",
       input=the_key)
    margv = ["docker", "run", "--rm", "--network", n_drill, "--user", "65532:65532", "--group-add", "10001", "--read-only",
             "--cap-drop", "ALL", "-v", f"{kv}:{kdir}:ro"]
    for k, v in menv.items():
        margv += ["-e", f"{k}={v}"]
    return sh(*margv, mimage, *margs, "--format", "json")

PROBE = r'''
import json, os, sys, urllib.request
b = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "ask", "arguments": {"q": "hello"}}}).encode()
h = {"content-type": "application/json", "x-fuse-key": sys.stdin.read().strip(),
     "x-fuse-agent-id": "agent://acme.example/agents/typed-user", "x-fuse-run-id": "gate-broker-caller-1"}
print(urllib.request.urlopen(urllib.request.Request("http://tokenfuse-mcp-broker:4200/mcp", data=b, headers=h), timeout=10).read().decode())
'''

def statuses(report):
    out = {}
    for sc in (report or {}).get("results", []) or []:
        name = sc.get("name") or sc.get("scenario")
        if name:
            out[name] = sc.get("status")
    return out

pii_mode = benv.get("TOKENFUSE_MCP_DLP_PII", "off")
want = {"mcp-secret-in-arguments": "passed", "mcp-ungranted-tool-held": "passed",
        "mcp-pii-in-arguments": "passed" if pii_mode == "block" else "skipped_not_configured"}
summary = {}
try:
    rc, rep, raw, bc, seen = run_case("main")
    got = statuses(rep)
    if not can_drill:
        pass
    elif not got:
        fail(f"B: mockryx gave no report naming a scenario (exit {rc}), so this measured NOTHING: {raw.strip()[-300:]}")
    else:
        for name, w in want.items():
            if got.get(name) != w:
                fail(f"B: {name} came back {got.get(name)!r}, not {w!r} (52's PII mode is {pii_mode})")
        if rc != 0:
            fail(f"B: mockryx exited {rc} against the broker as 52 configures it: {raw.strip()[-400:]}")
        summary["main"] = got
    if '"code":-32004' not in bc or "when_no_grant" not in bc or "taint gate" in bc:
        fail(f"B: an agent's call with broker-caller was not judged by wardryx past the tool-call check; the broker answered: {bc[:300]}")
    if seen:
        fail("B: a key appears in what mockryx or the probe printed")

    if not can_drill:
        raise StopIteration
    rc, rep, raw, bc, seen = run_case("nogw", gw_drop=("drills-broker",))
    got = statuses(rep)
    if rc == 0 or got.get("mcp-ungranted-tool-held") == "passed" or "taint gate" not in raw:
        fail(f"C: with drills-broker left out of the gateway's keys the drills still passed (exit {rc}, {got}); the gateway half is not what this run measures")
    summary["nogw"] = got

    rc, rep, raw, bc, seen = run_case("wrongkey", wrong_key=True)
    got = statuses(rep)
    if rc == 0 or any(v == "passed" for v in got.values()):
        fail(f"C: with a key the broker does not hold the drills still passed (exit {rc}, {got}); the broker's door is not what this run measures")
    summary["wrongkey"] = got
except StopIteration:
    pass
except RuntimeError as e:
    fail(f"B: {e}. This measured NOTHING about the drills.")
finally:
    cleanup()

if problems:
    print(f"\n{len(problems)} problem(s). See CLAUDE.md invariant 85.")
    sys.exit(1)
m = summary["main"]
print("OK: the broker's two static callers are gateway keys of the same id; the drills-broker CronJob runs mockryx")
print(f"    {mimage.split('@')[0].split(':')[-1]} on /scenarios/mcp against {TF.split('@')[0].split('/')[-1]} with its own key, and passed:")
for name in sorted(m):
    print(f"      {m[name]:<24} {name}")
print("    broker-caller reaches wardryx past the tool-call check; without the gateway's drills-broker the drills fail")
print(f"    on the taint gate ({summary['nogw']}), and with a key the broker does not hold at its door ({summary['wrongkey']}).")
PY
