#!/usr/bin/env bash
#
# Enforces invariant 42 of CLAUDE.md: a typed deploy comes up green on its own.
# Every Secret a typed manifest reads, and is not optional about, is created by
# something here when it is absent, and never overwritten when it is present.
#
# WHAT THIS IS ABOUT
#
# `--with-typed` applies typryx (manifests/51) and tokenfuse's MCP broker in
# front of it (manifests/52). typryx reads `typryx-keys` and the broker reads
# `tokenfuse-mcp-broker-keys`, both through a non-optional envFrom, and the
# broker's vault (TOKENFUSE_MCP_SECRETS) has to carry typryx's own bearer. Until
# 2026-10-14 both were documented as made by hand and no launcher made them:
# measured on GCP that day, both pods stayed Pending, the rollout waited
# 300 s for each, and verify ended 15 passed / 1 failed; made by
# hand afterwards, 16 / 0. stack-single's installer mints the same pair.
# `@decided 2026-10-14`: the deploy scripts mint both when absent and never
# overwrite one. `typed/mode.sh door-secrets` is the one copy of that decision.
#
# WHAT THIS CHECKS
#
#   A. EVERY SECRET A TYPED MANIFEST READS IS MADE HERE. In manifests/51, 52 and
#      56 as committed, and in what typed/mode.sh renders for every mode with and
#      without the risk signal, each Secret named by an envFrom secretRef, a
#      secretKeyRef or a secret volume, not marked optional, is minted by
#      door-secrets, emitted by `typed/mode.sh secrets` for the same flags,
#      created by a tracked installer (`create secret generic <name>`), or named
#      in OPERATOR_MADE below with its reason (empty). A key read from a door
#      Secret is a key door-secrets writes.
#   B. EVERY LAUNCHER CALLS IT, IN ITS TYPED BRANCH, BEFORE THE RENDER. Launchers
#      are found as typed-mode-is-honest.sh finds them. Inside the
#      `if [ "$TYPED_EFFECTIVE" != off ]` block that renders through
#      typed/mode.sh, door-secrets is called with --have above the render, its
#      output goes to `create -f -`, and no code line hands it to `apply`
#      (`create` never replaces a Secret; `apply` would, and would keep every
#      value again in its last-applied annotation).
#   C. door-secrets ITSELF, IN EVERY STATE. Neither Secret: two Secret documents,
#      schema-valid (kubeconform, strict), typryx's bearer equal to the
#      broker vault's typryx_key, the two bearers different, each at least 32 of
#      A-Za-z0-9 and fresh on every run, the broker's key id bare (invariant 33),
#      the identity in the given trust domain, and no value on stderr while it
#      says how to read one. Both: nothing printed. Only typryx's: the broker's
#      alone, its vault carrying the existing bearer, which is never printed. Only
#      the broker's: a refusal and no document. Garbage in --have, an unreadable
#      bearer, a bad domain, no --have, typed off, and --have given to another
#      verb: refusals with no document.
#   D. door-callers (CLAUDE.md invariant 85). The broker's two static callers are the
#      gateway's own keys: a minted broker Secret carries broker-caller and drills-broker
#      with the secrets gateway-client-keys holds; a kept one gets the caller it lacks
#      appended, every entry it had byte for byte; a caller whose secret is not the
#      gateway's, or a gateway that holds neither, is a refusal with no patch; and no
#      value is on stderr.
#   E. EVERY LAUNCHER'S DOOR BLOCK, RUN. The lines from DOOR_HAVE to the line that
#      clears DOOR_DOCS are lifted from each launcher and run with a stand-in
#      `k_` over a stand-in cluster, from each of the four starting states. Both
#      Secrets end up present; one that existed is byte for byte what it was; the
#      broker's vault carries typryx's bearer; only the broker's present stops the
#      script; and no value appears on a k_ command line or in the output. Since
#      invariant 85 the block also reads the gateway's keys and runs door-callers: the
#      broker's static callers end up the gateway's, a kept broker Secret keeps every
#      entry and gains drills-broker, and one whose broker-caller is not the gateway's
#      stops the block with the cluster unchanged.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No typed/mode.sh or typed manifest, no Secret reference found, no launcher,
# no door block in a launcher, or no kubeconform: each is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import base64, json, os, pathlib, re, shutil, subprocess, sys, tempfile

MODE = "typed/mode.sh"
TYPED = ["manifests/51-typryx.yaml", "manifests/52-tokenfuse-mcp-broker.yaml",
         "manifests/56-typryx-wardryx-proxy.yaml"]
DOOR = ("typryx-keys", "tokenfuse-mcp-broker-keys")
NS = "agent-stack"
# Secrets a typed manifest reads that nothing here creates, each with the reason an
# operator has to make it. Empty since 2026-10-14: the launchers mint the door.
OPERATOR_MADE = {
}
ROOT = os.getcwd()

problems = []
def bad(msg):
    problems.append(msg)

for p in [MODE] + TYPED:
    if not os.path.isfile(p):
        print(f"FAIL: {p} does not exist, so this measured NOTHING about the typed-answer door.")
        sys.exit(1)

kc = shutil.which("kubeconform")
if not kc:
    gp = subprocess.run(["go", "env", "GOPATH"], capture_output=True, text=True).stdout.strip() if shutil.which("go") else ""
    cand = pathlib.Path(gp) / "bin" / "kubeconform" if gp else None
    kc = str(cand) if cand and cand.exists() else None
if not kc:
    print("FAIL: kubeconform is not on PATH, so the minted Secrets were not validated.")
    print("      A schema check that cannot run is not a schema check that passed.")
    sys.exit(1)

tmp = pathlib.Path(tempfile.mkdtemp())
(tmp / "jev.key").write_text("fake-jev-key-not-a-real-key-0c4d\n")
(tmp / "model.key").write_text("fake-model-key-not-a-real-key-9e1f\n")
JEV = ["--typed-mode", "jev", "--typed-jev-key-file", str(tmp / "jev.key")]
OWN = ["--typed-mode", "own-model", "--typed-model-url", "http://10.1.2.3:11434/v1",
       "--typed-model-name", "qwen2.5:7b", "--typed-model-key-file", str(tmp / "model.key")]


def mode(*args, stdin=""):
    return subprocess.run(["bash", MODE, *args], input=stdin, capture_output=True, text=True)


def b64(s):
    return base64.b64encode(s.encode()).decode()


def secret_docs(text):
    """Secret documents in the fixed shape typed/mode.sh prints, data decoded."""
    out = []
    for doc in re.split(r"(?m)^---\s*$", text):
        if not doc.strip():
            continue
        kind = re.search(r"(?m)^kind:\s*(\S+)\s*$", doc)
        name = re.findall(r"(?m)^  name:\s*(\S+)\s*$", doc)
        ns = re.search(r"(?m)^  namespace:\s*(\S+)\s*$", doc)
        data = {}
        m = re.search(r"(?ms)^data:\s*\n(.*)", doc)
        bad_b64 = []
        if m:
            for k, v in re.findall(r"(?m)^  ([A-Za-z0-9_.-]+):\s*(\S+)\s*$", m.group(1)):
                try:
                    data[k] = base64.b64decode(v, validate=True).decode()
                except Exception:
                    bad_b64.append(k)
        out.append({"kind": kind.group(1) if kind else None, "names": name,
                    "name": name[0] if len(name) == 1 else None,
                    "namespace": ns.group(1) if ns else None, "data": data, "bad_b64": bad_b64})
    return out


SECRET_RE = re.compile(r"^[A-Za-z0-9]{32,}$")
TYPRYX_SCOPE = "typryx_key=tools:ask|ask_freeform|list_questions"
BARE = re.compile(r"^[A-Za-z0-9._-]+$")


# ---- C. door-secrets itself ----------------------------------------------------------
GW_BC = "gatewaybrokercallerkey0from0the0mint0Q1"
GW_DB = "gatewaydrillsbrokerkey0from0the0mint0W2"
GW_SPEC = f"felyxkey0000000000000000000000000000000:felyx,{GW_BC}:broker-caller,{GW_DB}:drills-broker"
WANT_KEYS = f"{GW_BC}:broker-caller,{GW_DB}:drills-broker"


def door(have, stdin="", extra=(), flags=("--with-typed",), gw=GW_SPEC):
    """door-secrets fed as a launcher feeds it: typryx's TYPRYX_KEYS, then the gateway's client keys."""
    return mode("door-secrets", *flags, *extra, "--have", have, stdin=stdin + "\n" + b64(gw) + "\n")


def callers(broker_spec, gw=GW_SPEC, flags=("--with-typed",)):
    return mode("door-callers", *flags, stdin=b64(broker_spec) + "\n" + b64(gw) + "\n")


def check_neither(label, r, domain):
    """Two documents, consistent, schema-valid; returns (typryx bearer, broker key) or None."""
    if r.returncode != 0:
        bad(f"C {label}: door-secrets exited {r.returncode} with neither Secret present: {r.stderr.strip()[:200]}")
        return None
    ds = secret_docs(r.stdout)
    names = [d["name"] for d in ds]
    if names != list(DOOR):
        bad(f"C {label}: with neither Secret present door-secrets printed {names}, not {list(DOOR)}")
        return None
    for d in ds:
        if d["kind"] != "Secret" or d["namespace"] != NS or d["bad_b64"]:
            bad(f"C {label}: {d['name']} is not a Secret in {NS} with base64 data ({d['kind']}, {d['namespace']}, {d['bad_b64']})")
    t, b = ds[0]["data"], ds[1]["data"]
    if set(t) != {"TYPRYX_KEYS"}:
        bad(f"C {label}: typryx-keys carries {sorted(t)}, not exactly TYPRYX_KEYS")
        return None
    if set(b) != {"TOKENFUSE_MCP_KEYS", "TOKENFUSE_MCP_SECRETS", "TOKENFUSE_MCP_SECRET_SCOPES"}:
        bad(f"C {label}: tokenfuse-mcp-broker-keys carries {sorted(b)}, not TOKENFUSE_MCP_KEYS, TOKENFUSE_MCP_SECRETS and TOKENFUSE_MCP_SECRET_SCOPES")
        return None
    bearer, sep, ident = t["TYPRYX_KEYS"].partition("=")
    if not sep or ident != f"agent://{domain}/typed-broker":
        bad(f"C {label}: TYPRYX_KEYS is not `<bearer>=agent://{domain}/typed-broker` (identity {ident!r})")
    entries = b["TOKENFUSE_MCP_KEYS"].split(",")
    for e in entries:
        if not BARE.match(e.rpartition(":")[2]):
            bad(f"C {label}: TOKENFUSE_MCP_KEYS has an entry whose key id {e.rpartition(':')[2]!r} is not a bare name (invariant 33)")
    if b["TOKENFUSE_MCP_KEYS"] != WANT_KEYS:
        bad(f"C {label}: TOKENFUSE_MCP_KEYS is not exactly the gateway's broker-caller and drills-broker, so a caller the broker admits is refused at the gateway's tool-call check (invariant 85)")
    secret = entries[0].rpartition(":")[0]
    if b["TOKENFUSE_MCP_SECRETS"] != f"typryx_key={bearer}":
        bad(f"C {label}: the broker's vault (TOKENFUSE_MCP_SECRETS) does not carry typryx's own bearer, so every call through the broker would be refused")
    if b["TOKENFUSE_MCP_SECRET_SCOPES"] != TYPRYX_SCOPE:
        bad(f"C {label}: the broker's scope rules (TOKENFUSE_MCP_SECRET_SCOPES) are not exactly typryx's, so the broker would stop at start (a vault entry with no rule) or leave typryx's key open to any tool")
    for what, v in (("typryx's bearer", bearer),):
        if not SECRET_RE.match(v):
            bad(f"C {label}: {what} is {len(v)} character(s), not at least 32 of A-Za-z0-9")
    if bearer == secret:
        bad(f"C {label}: typryx's bearer and the broker's key are the same, which collapses two doors into one")
    for v in (bearer, secret):
        if v and (v in r.stderr or b64(v) in r.stderr):
            bad(f"C {label}: a minted value appears on stderr; the door says how to read a value, never the value")
    if "get secret tokenfuse-mcp-broker-keys" not in r.stderr or "get secret typryx-keys" not in r.stderr:
        bad(f"C {label}: door-secrets does not say how to read the values back")
    f = tmp / f"door-{label.replace(' ', '-')}.yaml"
    f.write_text(r.stdout)
    v = subprocess.run([kc, "-strict", "-summary", str(f)], capture_output=True, text=True)
    if v.returncode != 0:
        bad(f"C {label}: the minted Secrets do not validate: {(v.stdout + v.stderr).strip()[:200]}")
    return bearer, secret


r1 = door("")
first = check_neither("neither", r1, "set-me.invalid")
r2 = door("")
second = check_neither("neither, again", r2, "set-me.invalid")
if first and second and first[0] == second[0]:
    bad("C neither: two runs minted the same typryx bearer, which is not a secret")
for label, gw in (("a gateway with no broker-caller", f"x0000000000000000000000000000000000000:felyx,{GW_DB}:drills-broker"),
                  ("a gateway with no drills-broker", f"{GW_BC}:broker-caller"),
                  ("no gateway keys at all", "")):
    for have, st in (("", ""), ("secret/typryx-keys", b64("kept0bearer0from0an0earlier0run0Q7xV2m=agent://acme.example/typed-broker"))):
        r = door(have, stdin=st, gw=gw)
        if r.returncode == 0 or r.stdout.strip() or "gateway" not in r.stderr:
            bad(f"C {label}, --have {have!r}: door-secrets exited {r.returncode} and printed {len(r.stdout)} byte(s); a broker given a caller the gateway does not hold refuses every call at the tool-call check, so it has to stop and say why")
        if GW_BC in r.stderr or GW_DB in r.stderr:
            bad(f"C {label}: a gateway key appears on stderr")
check_neither("neither, with a trust domain", door("", extra=("--trust-domain", "acme.example")), "acme.example")
door_names = [d["name"] for d in secret_docs(r1.stdout)]

for label, r in (
    ("a domain that is not one", door("", extra=("--trust-domain", "acme example;x"))),
    ("typed off", door("", flags=())),
    ("--have names another Secret", door("secret/stack-keys")),
    ("no --have", mode("door-secrets", "--with-typed")),
    ("--have with another verb", mode("render", "--with-typed", "--have", "")),
):
    if r.returncode == 0 or r.stdout.strip():
        bad(f"C {label}: door-secrets exited {r.returncode} and printed {len(r.stdout)} byte(s); it has to refuse and print no document")

EXISTING = "kept0bearer0from0an0earlier0run0Q7xV2m"
spec = f"{EXISTING}=agent://acme.example/typed-broker,second0bearer=agent://acme.example/other"
r = door("secret/typryx-keys secret/tokenfuse-mcp-broker-keys", stdin=b64(spec))
if r.returncode != 0 or r.stdout.strip() or EXISTING in r.stderr:
    bad(f"C both present: door-secrets exited {r.returncode}, printed {len(r.stdout)} byte(s); with both present it keeps both and prints nothing")

r = door("secret/typryx-keys", stdin=b64(spec))
ds = secret_docs(r.stdout)
if r.returncode != 0 or [d["name"] for d in ds] != ["tokenfuse-mcp-broker-keys"]:
    bad(f"C only typryx-keys: door-secrets exited {r.returncode} and printed {[d['name'] for d in ds]}; it has to print the broker's alone and leave typryx-keys to stand")
else:
    b = ds[0]["data"]
    if b.get("TOKENFUSE_MCP_SECRETS") != f"typryx_key={EXISTING}":
        bad("C only typryx-keys: the broker's vault does not carry the bearer of the typryx-keys that exists")
    if b.get("TOKENFUSE_MCP_SECRET_SCOPES") != TYPRYX_SCOPE:
        bad("C only typryx-keys: the broker's Secret made beside the kept typryx-keys carries no scope rule for typryx's key")
    if b.get("TOKENFUSE_MCP_KEYS") != WANT_KEYS:
        bad("C only typryx-keys: the broker's static callers are not exactly the gateway's broker-caller and drills-broker")
    if EXISTING in r.stderr or GW_BC in r.stderr or GW_DB in r.stderr:
        bad("C only typryx-keys: a value appears on stderr")

for label, stdin in (("an empty bearer", ""), ("not base64", "%%% not base64 %%%"),
                     ("no `=` in TYPRYX_KEYS", b64("justabearer"))):
    r = door("secret/typryx-keys", stdin=stdin)
    if r.returncode == 0 or r.stdout.strip():
        bad(f"C only typryx-keys, {label}: door-secrets exited {r.returncode} and printed a document; it has to refuse")

r = door("secret/tokenfuse-mcp-broker-keys")
if r.returncode == 0 or r.stdout.strip() or "typryx-keys" not in r.stderr:
    bad(f"C only the broker's: door-secrets exited {r.returncode} and printed {len(r.stdout)} byte(s); a fresh typryx key would not match the broker's vault, so it has to stop and say why")


# ---- D. door-callers ---------------------------------------------------------------------
def patch_keys(r):
    try:
        return base64.b64decode(json.loads(r.stdout)["data"]["TOKENFUSE_MCP_KEYS"]).decode()
    except Exception:
        return None


KEPT = f"{GW_BC}:broker-caller,operator0added0caller0key0000000000000:my-bot"
r = callers(KEPT)
got = patch_keys(r)
if r.returncode != 0 or got != f"{KEPT},{GW_DB}:drills-broker":
    bad(f"D a kept broker Secret without drills-broker: door-callers exited {r.returncode} and patched {got!r}; it has to append the gateway's drills-broker and keep every entry byte for byte")
r = callers(f"{GW_DB}:drills-broker,{GW_BC}:broker-caller")
if r.returncode != 0 or r.stdout.strip():
    bad(f"D a broker Secret that agrees: door-callers exited {r.returncode} and printed {len(r.stdout)} byte(s); it has to print nothing")
for label, bspec, gw in (
    ("a broker-caller that is not the gateway's", "someone0elses0broker0caller0key00000000:broker-caller", GW_SPEC),
    ("a drills-broker that is not the gateway's", f"{GW_BC}:broker-caller,another0drills0broker0key0000000000000:drills-broker", GW_SPEC),
    ("a gateway that holds no drills-broker", f"{GW_BC}:broker-caller", f"{GW_BC}:broker-caller"),
    ("an empty broker Secret", "", GW_SPEC),
):
    r = callers(bspec, gw=gw)
    if r.returncode == 0 or r.stdout.strip():
        bad(f"D {label}: door-callers exited {r.returncode} and printed {len(r.stdout)} byte(s); it has to refuse with no patch")
    if any(v in r.stderr for v in (GW_BC, GW_DB, "someone0elses0broker0caller0key00000000")):
        bad(f"D {label}: a key appears on stderr")
r = callers(KEPT, flags=())
if r.returncode == 0 or r.stdout.strip():
    bad("D typed off: door-callers did not refuse")


# ---- A. every Secret a typed manifest reads is made here -------------------------------
def code_of(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


REF = re.compile(r"\b(secretRef|secretKeyRef|secret)\s*:\s*(\{[^{}]*\}|$)", re.M)


def refs(text):
    text = code_of(text)
    found = []
    for m in REF.finditer(text):
        body = m.group(2)
        if not body.startswith("{"):
            start = text.rfind("\n", 0, m.start()) + 1
            col = m.start() - start
            lines = []
            for l in text[m.end():].split("\n")[1:]:
                if l.strip() and (len(l) - len(l.lstrip())) > col:
                    lines.append(l)
                else:
                    break
            body = "\n".join(lines)
        name = re.search(r"\b(?:secretName|name)\s*:\s*[\"']?([A-Za-z0-9.-]+)", body)
        key = re.search(r"\bkey\s*:\s*[\"']?([A-Za-z0-9_.-]+)", body)
        optional = re.search(r"\boptional\s*:\s*true\b", body) is not None
        found.append((m.group(1), name.group(1) if name else None, key.group(1) if key else None, optional))
    return found


installer_made = set()
tracked = subprocess.run(["git", "ls-files", "*.sh"], capture_output=True, text=True).stdout.split()
for p in tracked:
    if p.startswith("scripts/") or not os.path.isfile(p):
        continue
    # two spellings of a creator: the kubectl line, and the manifest a secret_doc
    # call builds on stdin (CLAUDE.md invariant 60)
    for m in re.finditer(r"(?:create secret generic|secret_doc)\s+([a-z0-9][a-z0-9.-]*)", code_of(open(p).read())):
        installer_made.add(m.group(1))

door_keys = {}
for d in secret_docs(r1.stdout):
    door_keys[d["name"]] = set(d["data"])

subjects = [(p, open(p).read(), set()) for p in TYPED]
for label, flags in (("stub", ["--with-typed"]), ("jev", JEV), ("own-model", OWN)):
    for risk in ([], ["--typed-risk-signal"]):
        f = flags + risk
        lab = f"the {label} render" + (" with the risk signal" if risk else "")
        rr = mode("render", *f)
        if rr.returncode != 0:
            bad(f"A {lab}: typed/mode.sh render exited {rr.returncode}: {rr.stderr.strip()[:200]}")
            continue
        made = {d["name"] for d in secret_docs(mode("secrets", *f).stdout) if d["name"]}
        subjects.append((lab, rr.stdout, made))

counted = 0
for lab, text, made in subjects:
    for form, name, key, optional in refs(text):
        counted += 1
        if name is None:
            bad(f"A {lab}: a {form} this cannot read a Secret name from; an unparsable reference is a fault, not a pass")
            continue
        if optional:
            continue
        if name in door_names:
            if form == "secretKeyRef" and key not in door_keys.get(name, set()):
                bad(f"A {lab}: reads key {key!r} of {name}, which door-secrets does not write")
            continue
        if name in made or name in installer_made or name in OPERATOR_MADE:
            continue
        bad(f"A {lab}: reads Secret {name} ({form}, not optional) and nothing here creates it: not "
            "door-secrets, not `typed/mode.sh secrets`, not an installer, and not named in OPERATOR_MADE "
            "with its reason. The pod would sit in CreateContainerConfigError until somebody made it by hand.")
if counted == 0:
    bad("A: no Secret reference was found in the typed manifests or their renders, so this measured NOTHING")


# ---- B and E. the launchers ----------------------------------------------------------------
def is_launcher(path):
    text = pathlib.Path(path).read_text()
    return (re.search(r"^\s*--with-typed\)", text, re.M) is not None
            and re.search(r'^[^#]*k_ "apply -k[^"]*manifests"', text, re.M) is not None)


launchers = [p for p in tracked if os.path.isfile(p) and is_launcher(p)]
if not launchers:
    bad("B: no launcher parses --with-typed and applies the manifests, so this measured NOTHING about the launchers")

STUB = tmp / "stub_k.py"
STUB.write_text(r'''
import base64, json, os, re, sys
cmd = sys.argv[1]
cluster = os.environ["CLUSTER"]
with open(os.environ["ARGV_LOG"], "a") as f:
    f.write(cmd + "\n")
def path(n): return os.path.join(cluster, n + ".json")
def exists(n): return os.path.exists(path(n))
if cmd == "-n agent-stack get secret typryx-keys tokenfuse-mcp-broker-keys --ignore-not-found -o name":
    for n in ("typryx-keys", "tokenfuse-mcp-broker-keys"):
        if exists(n):
            print("secret/" + n)
    sys.exit(0)
if cmd == "-n agent-stack get secret typryx-keys --ignore-not-found -o jsonpath='{.data.TYPRYX_KEYS}'":
    if exists("typryx-keys"):
        sys.stdout.write(json.load(open(path("typryx-keys")))["TYPRYX_KEYS"])
    sys.exit(0)
if cmd == "-n agent-stack get secret gateway-client-keys -o jsonpath='{.data.client_keys}'":
    sys.stdout.write(json.load(open(path("gateway-client-keys")))["client_keys"])
    sys.exit(0)
if cmd == "-n agent-stack get secret tokenfuse-mcp-broker-keys -o jsonpath='{.data.TOKENFUSE_MCP_KEYS}'":
    if not exists("tokenfuse-mcp-broker-keys"):
        sys.stderr.write('Error from server (NotFound): secrets "tokenfuse-mcp-broker-keys" not found\n')
        sys.exit(1)
    sys.stdout.write(json.load(open(path("tokenfuse-mcp-broker-keys")))["TOKENFUSE_MCP_KEYS"])
    sys.exit(0)
if cmd == "-n agent-stack patch secret tokenfuse-mcp-broker-keys --type merge --patch-file /dev/stdin":
    body = json.load(sys.stdin)
    cur = json.load(open(path("tokenfuse-mcp-broker-keys")))
    cur.update(body["data"])
    json.dump(cur, open(path("tokenfuse-mcp-broker-keys"), "w"))
    print("secret/tokenfuse-mcp-broker-keys patched")
    sys.exit(0)
if cmd == "-n agent-stack create -f -":
    rc = 0
    for doc in re.split(r"(?m)^---\s*$", sys.stdin.read()):
        if not doc.strip():
            continue
        name = re.search(r"(?m)^  name:\s*(\S+)", doc).group(1)
        data = dict(re.findall(r"(?m)^  ([A-Z_]+):\s*(\S+)\s*$", doc.split("\ndata:\n", 1)[1]))
        if exists(name):
            sys.stderr.write('Error from server (AlreadyExists): secrets "%s" already exists\n' % name)
            rc = 1
            continue
        json.dump(data, open(path(name), "w"))
        print("secret/%s created" % name)
    sys.exit(rc)
sys.stderr.write("the stand-in cluster does not know this command: " + cmd + "\n")
sys.exit(3)
''')


def dec(v):
    return base64.b64decode(v).decode()


ran = 0
for p in launchers:
    lines = pathlib.Path(p).read_text().split("\n")
    live = [(i, l) for i, l in enumerate(lines) if not l.lstrip().startswith("#")]
    ren = [i for i, l in live if re.search(r'typed/mode\.sh"?\s+render\b', l)]
    if not ren:
        bad(f"B {p}: never renders through typed/mode.sh, so there is no typed branch to judge")
        continue
    opens = [i for i, l in live if i < ren[0] and re.match(r'if \[ "\$TYPED_EFFECTIVE" != off \]; then\s*$', l)]
    if not opens:
        bad(f"B {p}: its render is not inside an `if [ \"$TYPED_EFFECTIVE\" != off ]; then` block")
        continue
    top = opens[-1]
    end = next((i for i in range(top + 1, len(lines)) if lines[i] == "fi"), None)
    if end is None:
        bad(f"B {p}: the typed branch at line {top + 1} never closes with a `fi` at its own indent")
        continue
    block = [(i, l) for i, l in live if top < i < end]
    dr = [i for i, l in block if re.search(r'typed/mode\.sh"?\s+door-secrets\b', l)]
    if not dr:
        bad(f"B {p}: its typed branch never calls typed/mode.sh door-secrets, so a typed deploy waits on two Secrets made by hand")
        continue
    if dr[0] > ren[0]:
        bad(f"B {p}: calls door-secrets at line {dr[0] + 1}, after the render at line {ren[0] + 1}; the door has to exist before the pods that read it")
    if not any("--have" in lines[i] for i in dr):
        bad(f"B {p}: calls door-secrets without --have, so it cannot know what exists")
    if not any(re.search(r'k_ "-n agent-stack create -f -"', l) for i, l in block if i > dr[0]):
        bad(f"B {p}: the door's documents never reach `create -f -`")
    applied = [i for i, l in block if "DOOR_DOCS" in l and re.search(r"\bapply\b", l.split("#", 1)[0])]
    if applied:
        bad(f"B {p}: line {applied[0] + 1} hands the door's Secrets to apply, which overwrites a Secret and keeps a copy of every value in its last-applied annotation")

    # E. lift the door block and run it over a stand-in cluster, from each starting state.
    s_i = next((i for i, l in block if l.lstrip().startswith('DOOR_HAVE="$(k_')), None)
    e_i = next((i for i, l in block if l.strip() == 'DOOR_DOCS=""'), None)
    if s_i is None or e_i is None or e_i < s_i:
        bad(f"E {p}: no door block from `DOOR_HAVE=\"$(k_` to `DOOR_DOCS=\"\"` to run")
        continue
    body = "\n".join(lines[s_i:e_i + 1])
    for state in ("neither", "both", "only typryx-keys", "only the broker's", "both, a caller not the gateway's"):
        cl = pathlib.Path(tempfile.mkdtemp(dir=tmp))
        log = cl / "argv.log"
        before = {}
        kept_bc = "kept0broker0key0from0an0earlier0run0Zk3"
        # The gateway's keys as lib/identity-mint.sh leaves them: a kept broker-caller is the one the door holds.
        gwbc = GW_BC if state in ("neither", "only typryx-keys", "both, a caller not the gateway's") else kept_bc
        gw_spec = f"felyxkey0000000000000000000000000000000:felyx,{gwbc}:broker-caller,{GW_DB}:drills-broker"
        (cl / "gateway-client-keys.json").write_text(json.dumps({"client_keys": b64(gw_spec)}))
        if state in ("both", "only typryx-keys", "both, a caller not the gateway's"):
            (cl / "typryx-keys.json").write_text(json.dumps({"TYPRYX_KEYS": b64(spec)}))
        if state in ("both", "only the broker's", "both, a caller not the gateway's"):
            (cl / "tokenfuse-mcp-broker-keys.json").write_text(json.dumps({
                "TOKENFUSE_MCP_KEYS": b64(f"{kept_bc}:broker-caller"),
                "TOKENFUSE_MCP_SECRETS": b64(f"typryx_key={EXISTING}")}))
        for f in cl.glob("*.json"):
            before[f.name] = f.read_bytes()
        script = (
            "set -euo pipefail\n"
            f"ROOT={json.dumps(ROOT)}\n"
            "TYPED_ARGS=(--with-typed)\n"
            "TRUST_DOMAIN=acme.example\n"
            "die() { printf 'die: %s\\n' \"$*\" >&2; exit 1; }\n"
            f"k_() {{ python3 {json.dumps(str(STUB))} \"$*\"; }}\n"
            + body + "\necho DOOR-BLOCK-DONE\n"
        )
        env = dict(os.environ, CLUSTER=str(cl), ARGV_LOG=str(log))
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env, stdin=subprocess.DEVNULL)
        ran += 1
        where = f"E {p}, {state}"
        after = {f.name: f.read_bytes() for f in cl.glob("*.json")}
        argv = log.read_text() if log.exists() else ""
        if state in ("only the broker's", "both, a caller not the gateway's"):
            if r.returncode == 0 or "DOOR-BLOCK-DONE" in r.stdout or "die:" not in r.stderr:
                bad(f"{where}: the block went on (exit {r.returncode}); it has to stop with the reason")
            if after != before:
                bad(f"{where}: the block changed the stand-in cluster although it had to stop")
            continue
        if r.returncode != 0 or "DOOR-BLOCK-DONE" not in r.stdout:
            bad(f"{where}: the block stopped (exit {r.returncode}): {r.stderr.strip()[-300:]}")
            continue
        for n, v in before.items():
            if n == "tokenfuse-mcp-broker-keys.json" and state == "both":
                continue
            if after.get(n) != v:
                bad(f"{where}: {n[:-5]} existed and is no longer byte for byte what it was")
        if state == "both":
            was, now = json.loads(before["tokenfuse-mcp-broker-keys.json"]), json.loads(after["tokenfuse-mcp-broker-keys.json"])
            if now.get("TOKENFUSE_MCP_SECRETS") != was["TOKENFUSE_MCP_SECRETS"] or \
                    dec(now.get("TOKENFUSE_MCP_KEYS", "")) != dec(was["TOKENFUSE_MCP_KEYS"]) + f",{GW_DB}:drills-broker":
                bad(f"{where}: the kept broker Secret did not keep every entry byte for byte and gain the gateway's drills-broker")
        if set(after) != {"typryx-keys.json", "tokenfuse-mcp-broker-keys.json", "gateway-client-keys.json"}:
            bad(f"{where}: the stand-in cluster holds {sorted(after)} after the block, not both door Secrets whole")
            continue
        t = json.loads(after["typryx-keys.json"])
        b = json.loads(after["tokenfuse-mcp-broker-keys.json"])
        # An existing broker Secret is kept byte for byte, whatever shape it has; one made now carries the scope rule too.
        want_b = {"TOKENFUSE_MCP_KEYS", "TOKENFUSE_MCP_SECRETS"} | (set() if state == "both" else {"TOKENFUSE_MCP_SECRET_SCOPES"})
        if set(t) != {"TYPRYX_KEYS"} or set(b) != want_b:
            bad(f"{where}: the stand-in cluster holds typryx-keys with {sorted(t)} and the broker's with "
                f"{sorted(b)}, not both door Secrets whole")
            continue
        bearer = dec(t["TYPRYX_KEYS"]).split(",")[0].split("=")[0]
        if dec(b["TOKENFUSE_MCP_SECRETS"]) != f"typryx_key={bearer}":
            bad(f"{where}: the broker's vault does not carry typryx's bearer")
        if state == "neither" and not dec(t["TYPRYX_KEYS"]).endswith("=agent://acme.example/typed-broker"):
            bad(f"{where}: the minted typryx identity is not in the launcher's trust domain")
        if state == "both" and "create -f -" in argv:
            bad(f"{where}: the block ran `create` with both Secrets present")
        bk = dict((e.rpartition(":")[2], e.rpartition(":")[0]) for e in dec(b["TOKENFUSE_MCP_KEYS"]).split(","))
        if bk.get("broker-caller") != gwbc or bk.get("drills-broker") != GW_DB:
            bad(f"{where}: the broker's static callers are not the gateway's broker-caller and drills-broker after the block")
        values = [bearer, gwbc, GW_DB]
        for v in values:
            if v and (v in argv or v in r.stdout or v in r.stderr):
                bad(f"{where}: a door value appears on a k_ command line or in the output")
                break

if problems:
    for p in problems:
        print("FAIL: " + p)
    print()
    print(f"{len(problems)} problem(s). See CLAUDE.md invariant 42.")
    sys.exit(1)

print(f"OK: {counted} Secret reference(s) in the typed manifests and {len(subjects) - len(TYPED)} renders, each made here;")
print(f"    door-secrets mints {', '.join(door_names)} when neither exists, keeps both, derives the broker's from")
print(f"    an existing typryx-keys, stops on the broker's alone, and prints no value; the broker's static callers")
print(f"    are the gateway's, and door-callers keeps a kept broker Secret in step or stops;")
print(f"    {len(launchers)} launcher(s) call it in the typed branch before the render, and their door blocks ran")
print(f"    {ran} times over a stand-in cluster from all five starting states.")
PY
