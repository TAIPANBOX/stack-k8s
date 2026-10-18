#!/usr/bin/env bash
#
# Enforces invariant 50 of CLAUDE.md: the gateway never answers an unnamed caller.
# It does not start without client keys, its identity map is strict, and a deploy
# given no files mints a key for the console's copilot (Felyx) and one for the
# operator's agents, binds each to its own agent ids, and never rewrites either.
#
# WHAT THIS IS ABOUT
#
# Finding F-001 of the 2026-10-17 review: with TOKENFUSE_CLIENT_KEYS unset the
# gateway admits every caller and takes `x-fuse-agent-id` as the caller wrote it,
# so one agent can speak as another and take its policy and its budget. This
# launcher read the keys through an OPTIONAL reference and shipped no object, so a
# default cluster answered anything its NetworkPolicy let in. @decided 2026-10-17
# (paraphrased): close the review's findings, defaults first. stack-single made the
# same change (its invariant 35), and this is the same design in a cluster's shape.
#
# WHAT THIS CHECKS
#
#   A. THE MANIFESTS. Every container that runs the tokenfuse gateway with no
#      subcommand reads TOKENFUSE_CLIENT_KEYS from gateway-client-keys/client_keys,
#      NOT optional, and sets TOKENFUSE_IDENTITY_STRICT to the literal enforce,
#      once. The console reads Felyx's key from felyx-client-key/client_key and
#      names it to the copilot as env:GENARYX_COPILOT_FUSE_KEY; no other container
#      names felyx-client-key.
#   B. THE MINT, lib/identity-mint.sh's block lifted out and run against a stand-in
#      cluster that answers exactly the kubectl calls it makes:
#        - an empty cluster: the Secret (labelled minted) holding
#          `<felyx>:felyx,<agents>:agents`, felyx-client-key holding the felyx
#          secret, the map's ConfigMap binding felyx to exactly Felyx's id and
#          agents to agent://<td>/agents/* (which cannot match Felyx's id), the
#          agents' key in a 0600 file, and the gateway and the console rolled once;
#        - a re-run writes nothing and rolls nothing, and keeps the file;
#        - a moved trust domain rewrites the map alone and rolls the gateway;
#        - a deleted felyx-client-key or key file comes back with the same secret;
#        - the operator's own Secret is left alone, nothing written;
#        - a map with no keys, a minted Secret edited by hand and a domain that is
#          not a name are refused with nothing written;
#        - no secret is on any kubectl command line or in anything printed, and the
#          closing note names the key file and the ids and never the key.
#   C. THE GATEWAY IMAGE the manifest pins reads the minted pair, through
#      identity/up.sh --check-only: two keys and the map, nothing refused.
#   D. THE ORDER. Each deploy script sources the library and calls the mint after
#      its `apply -k` and after its trust-domain patch, before it waits for
#      rollouts, and prints the note at its end; identity/mint.sh does the same for
#      a cluster applied by hand. The key file is gitignored and an operator-file
#      shape.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No gateway container, no mint block, or no Docker: each is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1


problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# ---- A. the manifests -------------------------------------------------------------
python3 - <<'PY' || problems=$((problems + 1))
import glob, re, sys

def live(line):
    return line.strip() and not line.strip().startswith("#")

def containers(path):
    """(name, image, command, args, text) for every container of every pod spec."""
    text = open(path).read()
    out = []
    for doc in re.split(r"(?m)^---\s*$", text):
        lines = doc.split("\n")
        i = 0
        while i < len(lines):
            m = re.match(r"^(\s*)(?:initContainers|containers):\s*$", lines[i])
            if not m:
                i += 1
                continue
            base = len(m.group(1))
            j = i + 1
            items, cur = [], None
            while j < len(lines):
                l = lines[j]
                if live(l) and len(l) - len(l.lstrip()) <= base:
                    break
                if re.match(r"^\s*- name:\s*\S", l) and (cur is None or len(l) - len(l.lstrip()) == cur[0]):
                    cur = (len(l) - len(l.lstrip()), [l])
                    items.append(cur)
                elif cur is not None:
                    cur[1].append(l)
                j += 1
            for _, body in items:
                t = "\n".join(x for x in body if live(x))
                name = re.match(r"^\s*- name:\s*(\S+)", body[0]).group(1)
                image = (re.search(r"(?m)^\s*image:\s*(\S+)", t) or [None, ""])[1]
                command = (re.search(r"(?m)^\s*command:\s*(\[.*\])", t) or [None, ""])[1]
                args = (re.search(r"(?m)^\s*args:\s*(\[.*\])", t) or [None, ""])[1]
                out.append((name, image, command, args, t))
            i = j
    return out

def env_entries(t, var):
    """The text of each env entry naming var: a flow mapping, or a block entry with its valueFrom."""
    lines = t.split("\n")
    found = []
    for k, l in enumerate(lines):
        if re.search(r"(^|[{\s])name:\s*" + re.escape(var) + r"\s*([,}]|$)", l):
            entry = [l]
            ind = len(l) - len(l.lstrip())
            for x in lines[k + 1:]:
                xi = len(x) - len(x.lstrip())
                if xi <= ind or x.lstrip().startswith("- "):
                    break
                entry.append(x)
            found.append("\n".join(entry))
    return found

def ref(entry, kind):
    m = re.search(kind + r":\s*\{([^}]*)\}", entry)
    if not m:
        return None
    f = dict(re.findall(r"(\w+):\s*\"?([^,\"}\s]+)\"?", m.group(1)))
    return f

problems = []
gateways = 0
for path in sorted(glob.glob("manifests/*.yaml")):
    for name, image, command, args, t in containers(path):
        where = f"{path} {name}"
        if "ghcr.io/taipanbox/tokenfuse:" in image and command.replace(" ", "") == '["/usr/local/bin/tokenfuse"]' and not args:
            gateways += 1
            e = env_entries(t, "TOKENFUSE_CLIENT_KEYS")
            if len(e) != 1:
                problems.append(f"{where} sets TOKENFUSE_CLIENT_KEYS {len(e)} time(s), not once, so it answers every caller or the later entry wins without a word.")
            else:
                f = ref(e[0], "secretKeyRef")
                if f is None or (f.get("name"), f.get("key")) != ("gateway-client-keys", "client_keys"):
                    problems.append(f"{where} does not read TOKENFUSE_CLIENT_KEYS from gateway-client-keys/client_keys, the Secret the deploy mints and identity/up.sh writes.")
                elif f.get("optional") == "true":
                    problems.append(f"{where} reads TOKENFUSE_CLIENT_KEYS optional: true, so a cluster with no Secret starts a gateway that answers every caller.")
            e = env_entries(t, "TOKENFUSE_IDENTITY_STRICT")
            vals = [re.search(r"value:\s*\"?([^\",}\s]*)", x) for x in e]
            vals = [v.group(1) if v else None for v in vals]
            if vals != ["enforce"]:
                problems.append(f"{where} sets TOKENFUSE_IDENTITY_STRICT {vals or 'nowhere'}, not the literal enforce once. Under warn or off a key speaking as an agent its binding does not name is only noted.")
        # The console Deployment, not the CronJobs that run the same image for verdryx.
        is_console = "genaryx-console" in image and path.endswith("20-console.yaml")
        if is_console:
            r = env_entries(t, "GENARYX_COPILOT_FUSE_KEY_REF")
            if len(r) != 1 or not re.search(r"value:\s*\"?env:GENARYX_COPILOT_FUSE_KEY\"?", r[0]):
                problems.append(f"{where} does not name GENARYX_COPILOT_FUSE_KEY_REF env:GENARYX_COPILOT_FUSE_KEY, so Felyx sends no key and the gateway refuses it 401.")
            k = env_entries(t, "GENARYX_COPILOT_FUSE_KEY")
            f = ref(k[0], "secretKeyRef") if len(k) == 1 else None
            if f is None or (f.get("name"), f.get("key")) != ("felyx-client-key", "client_key"):
                problems.append(f"{where} does not read GENARYX_COPILOT_FUSE_KEY from felyx-client-key/client_key, the Secret the deploy mints for Felyx.")
        elif re.search(r"\bfelyx-client-key\b", t):
            problems.append(f"{where} names felyx-client-key, Felyx's key; only the console reads it.")
if gateways == 0:
    print("FAIL: no container under manifests/ runs the tokenfuse gateway with no subcommand, so this gate")
    print("      measured NOTHING about who may call a metered door. Silence here is not health.")
    sys.exit(1)
for p in problems:
    print("FAIL: " + p)
if problems:
    sys.exit(1)
print(f"manifests: {gateways} gateway container(s) require gateway-client-keys and run strict; the console reads Felyx's key")
PY

# ---- B. the mint, against a stand-in cluster ----------------------------------------
GEN="$(cat lib/gen.sh 2>/dev/null)"
MINT="$(sed -n '/^# identity-mint: begin$/,/^# identity-mint: end$/p' lib/identity-mint.sh 2>/dev/null)"
mint_ok=0
if [ -z "$MINT" ]; then
  fail "lib/identity-mint.sh has no '# identity-mint: begin' .. 'end' block, so this measured nothing about the keys a cluster gets when nobody gave it any"
elif ! grep -q '^identity_mint_settle()' <<<"$MINT" || ! grep -q '^identity_mint_note()' <<<"$MINT" || ! grep -q '^identity_mint_map()' <<<"$MINT"; then
  fail "the identity-mint block defines no identity_mint_settle, identity_mint_note or identity_mint_map, so this measured nothing"
elif [ -z "$GEN" ]; then
  fail "lib/gen.sh is missing, so the mint has no generator to run with"
else
  mint_ok=1
fi

cat >"$scratch/k.py" <<'PY'
# A stand-in API server for exactly the calls lib/identity-mint.sh makes. It reads
# the ONE string the deploy scripts' runner is given, as a shell would, and fails
# loudly on anything else, so a changed library is noticed rather than faked.
import base64, copy, json, os, re, shlex, sys
cmd = sys.argv[1]
with open(os.environ["K_CALLS"], "a") as f:
    f.write(cmd + "\n")
a = shlex.split(cmd)
st = json.load(open(os.environ["K_STATE"]))
ns = None
if a[:1] == ["-n"]:
    ns, a = a[1], a[2:]
def save():
    json.dump(st, open(os.environ["K_STATE"], "w"), indent=1)
def die(msg, code=97):
    sys.stderr.write("stand-in kubectl: " + msg + ": " + cmd + "\n")
    sys.exit(code)
def bump():
    st["rv"] += 1
    return str(st["rv"])
def opt(name):
    return a[a.index(name) + 1] if name in a else None
def jsonpath(obj, expr):
    out = ""
    for lit, path in re.findall(r"([^{]*)\{([^}]*)\}", expr):
        out += lit
        cur = obj
        for part in re.split(r"(?<!\\)\.", path.lstrip(".")):
            part = part.replace("\\.", ".")
            cur = cur.get(part) if isinstance(cur, dict) else None
            if cur is None:
                break
        out += "" if cur is None else str(cur)
    return out
def key(kind, name):
    kind = {"secret": "secret", "configmap": "configmap", "cm": "configmap", "deployment": "deployment", "deploy": "deployment"}.get(kind)
    if kind is None:
        die("an unexpected kind")
    return kind + "/" + name
def merge(x, y):
    for k, v in y.items():
        if v is None:
            x.pop(k, None)
        elif isinstance(v, dict) and isinstance(x.get(k), dict):
            merge(x[k], v)
        else:
            x[k] = copy.deepcopy(v)
objs = st["objects"]
if a[:1] == ["get"]:
    o = opt("-o")
    names = [x for x in a[1:] if not x.startswith("-") and x not in (o or "",)]
    if o == "name":
        if all("/" in x for x in names):
            refs = [key(*x.split("/", 1)) for x in names]
        else:
            refs = [key(names[0], names[1])]
        for r in refs:
            if r in objs:
                print(r)
            elif "--ignore-not-found" not in a:
                die("NotFound", 1)
        sys.exit(0)
    if o and o.startswith("jsonpath="):
        r = key(names[0], names[1])
        if r not in objs:
            if "--ignore-not-found" in a:
                sys.exit(0)
            die("NotFound", 1)
        sys.stdout.write(jsonpath(objs[r], o[len("jsonpath="):]))
        sys.exit(0)
    die("an unexpected get")
elif a[:3] == ["create", "-f", "-"]:
    o = json.load(sys.stdin)
    r = key(o["kind"].lower(), o["metadata"]["name"])
    if r in objs:
        die("AlreadyExists", 1)
    if "stringData" in o:
        o.setdefault("data", {})
        for k, v in o.pop("stringData").items():
            o["data"][k] = base64.b64encode(v.encode()).decode()
    o["metadata"]["resourceVersion"] = bump()
    objs[r] = o
    st["writes"].append("create " + r)
    save()
elif a[:3] == ["create", "secret", "generic"]:
    r = key("secret", a[3])
    if r in objs:
        die("AlreadyExists", 1)
    o = {"kind": "Secret", "metadata": {"name": a[3], "resourceVersion": bump()}, "data": {}}
    for x in a[4:]:
        if x.startswith("--from-literal="):
            k, v = x[len("--from-literal="):].split("=", 1)
            o["data"][k] = base64.b64encode(v.encode()).decode()
    objs[r] = o
    st["writes"].append("create " + r)
    save()
elif a[:1] == ["patch"] and opt("--type") == "merge":
    r = key(a[1], a[2])
    if r not in objs:
        die("NotFound", 1)
    body = json.load(sys.stdin) if opt("--patch-file") == "/dev/stdin" else json.loads(opt("-p"))
    if "stringData" in body:
        body.setdefault("data", {})
        for k, v in body.pop("stringData").items():
            body["data"][k] = base64.b64encode(v.encode()).decode()
    before = json.dumps(objs[r], sort_keys=True)
    merge(objs[r], body)
    if json.dumps(objs[r], sort_keys=True) != before:
        objs[r]["metadata"]["resourceVersion"] = bump()
        st["writes"].append("patch " + r)
        if r.startswith("deployment/"):
            st["rolls"][a[2]] = st["rolls"].get(a[2], 0) + 1
    save()
else:
    die("an unexpected call")
PY

new_cluster() { # FILE DOMAIN: the stack applied, nothing identity-related yet
  python3 - "$1" "$2" <<'PY'
import json, sys
dep = lambda n: {"kind": "Deployment", "metadata": {"name": n, "resourceVersion": "1"},
                 "spec": {"template": {"metadata": {"labels": {"app": n}}}}}
json.dump({"rv": 100, "writes": [], "rolls": {},
           "objects": {"configmap/stack-wiring": {"kind": "ConfigMap", "metadata": {"name": "stack-wiring", "resourceVersion": "2"},
                                                  "data": {"TRAILRYX_TRUST_DOMAIN": sys.argv[2]}},
                       "deployment/tokenfuse-gateway": dep("tokenfuse-gateway"),
                       "deployment/genaryx-console": dep("genaryx-console")}},
          open(sys.argv[1], "w"), indent=1)
PY
}
# settle STATE KEYFILE: the block as the deploy runs it; prints what it printed and rc=
settle() {
  ( env -i PATH="$PATH" HOME="$HOME" K_STATE="$1" K_CALLS="$1.calls" GEN="$GEN" MINT="$MINT" KP="$scratch/k.py" KF="$2" bash -c '
      set -euo pipefail
      say() { printf ">> %s\n" "$*"; }
      die() { printf "die: %s\n" "$*"; exit 1; }
      k_() { python3 "$KP" "$*"; }
      eval "$GEN"; eval "$MINT"
      identity_mint_settle "$KF"
      printf "minted=%s\n" "$IDM_MINTED"
      identity_mint_note "$KF" >"$K_STATE.note"' 2>&1
    printf 'rc=%s\n' "$?" )
}
rc_of() { sed -n 's/^rc=//p' <<<"$1" | tail -1; }
q() { python3 -c 'import base64,json,sys;s=json.load(open(sys.argv[1]));o=s["objects"];print(eval(sys.argv[2]))' "$@"; }
data_of() { q "$1" "base64.b64decode(o['$2']['data']['$3']).decode() if '$2' in o else ''"; }
mode_of() { if stat -c %a "$1" >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
nwrites() { q "$1" 'len(s["writes"])'; }
rolls() { q "$1" "s['rolls'].get('$2', 0)"; }
setdomain() { python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));s["objects"]["configmap/stack-wiring"]["data"]["TRAILRYX_TRUST_DOMAIN"]=sys.argv[2];json.dump(s,open(sys.argv[1],"w"))' "$1" "$2"; }
drop() { python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));s["objects"].pop(sys.argv[2]);json.dump(s,open(sys.argv[1],"w"))' "$1" "$2"; }
put() { python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));s["objects"][sys.argv[2]]=json.loads(sys.argv[3]);json.dump(s,open(sys.argv[1],"w"))' "$1" "$2" "$3"; }
put_keys() { # STATE SPEC LABEL: a gateway-client-keys Secret holding SPEC, labelled LABEL (or not)
  python3 -c '
import base64, json, sys
s = json.load(open(sys.argv[1]))
md = {"name": "gateway-client-keys", "resourceVersion": "9"}
if sys.argv[3]:
    md["labels"] = {"taipanbox.dev/identity": sys.argv[3]}
s["objects"]["secret/gateway-client-keys"] = {"kind": "Secret", "metadata": md,
                                              "data": {"client_keys": base64.b64encode(sys.argv[2].encode()).decode()}}
json.dump(s, open(sys.argv[1], "w"))' "$1" "$2" "$3"
}
secret_in() { # STATE TEXT: 0 when TEXT holds any secret of the cluster's identity Secrets
  local s1 s2 s3
  s1="$(data_of "$1" secret/gateway-client-keys client_keys)"
  s2="$(data_of "$1" secret/felyx-client-key client_key)"
  for s3 in ${s1//,/ } "$s2"; do
    s3="${s3%:*}"
    [ -n "$s3" ] && grep -qF -- "$s3" <<<"$2" && return 0
  done
  return 1
}

if [ "$mint_ok" = 1 ]; then
  S="$scratch/c1.json"; KF="$scratch/agent-key"
  new_cluster "$S" acme.example
  out="$(settle "$S" "$KF")"
  if [ "$(rc_of "$out")" != 0 ]; then
    fail "an empty cluster was refused by the mint: $(grep '^die' <<<"$out")"
  else
    spec="$(data_of "$S" secret/gateway-client-keys client_keys)"
    felyx="$(data_of "$S" secret/felyx-client-key client_key)"
    fs="$(tr ',' '\n' <<<"$spec" | grep ':felyx$')"; as="$(tr ',' '\n' <<<"$spec" | grep ':agents$')"
    [[ "$spec" =~ ^[A-Za-z0-9]{40}:felyx,[A-Za-z0-9]{40}:agents,[A-Za-z0-9]{40}:drills,[A-Za-z0-9]{40}:broker,[A-Za-z0-9]{40}:costcrew$ ]] || fail "the minted Secret does not hold <40>:felyx,<40>:agents,<40>:drills,<40>:broker,<40>:costcrew"
    ds="$(tr ',' '\n' <<<"$spec" | grep ':drills$')"
    bk="$(tr ',' '\n' <<<"$spec" | grep ':broker$')"
    cc="$(tr ',' '\n' <<<"$spec" | grep ':costcrew$')"
    [ "$ds" != "$fs" ] && [ "$ds" != "$as" ] && [ "$ds" != "$bk" ] && [ "$ds" != "$cc" ] || fail "the drills and another key came out the same secret"
    [ "$bk" != "$fs" ] && [ "$bk" != "$as" ] && [ "$bk" != "$cc" ] || fail "the broker and another key came out the same secret"
    [ "$cc" != "$fs" ] && [ "$cc" != "$as" ] || fail "the CostCrew crew and another key came out the same secret"
    [ "$(data_of "$S" secret/drills-client-key client_key)" = "${ds%:drills}" ] \
      || fail "drills-client-key does not hold the key gateway-client-keys binds to the drills, so a drill would be refused 401"
    [ "$(data_of "$S" secret/broker-taint-key client_key)" = "${bk%:broker}" ] \
      || fail "broker-taint-key does not hold the key gateway-client-keys binds to the broker, so the broker's taint check would be refused 401"
    [ "$(data_of "$S" secret/costcrew-client-key client_key)" = "${cc%:costcrew}" ] \
      || fail "costcrew-client-key does not hold the key gateway-client-keys binds to the CostCrew crew, so the crew would be refused 401"
    [ "${fs%:felyx}" = "$felyx" ] || fail "felyx-client-key does not hold the key gateway-client-keys binds to felyx, so the console's copilot would be refused"
    [ "${fs%:felyx}" != "${as%:agents}" ] || fail "Felyx and the agents were given the same secret"
    [ "$(q "$S" "o['secret/gateway-client-keys']['metadata'].get('labels',{}).get('taipanbox.dev/identity')")" = minted ] \
      || fail "the minted Secret is not labelled taipanbox.dev/identity=minted, so a re-run cannot tell it from the operator's"
    if [ -f "$KF" ]; then
      [ "$(mode_of "$KF")" = 600 ] || fail "the agents' key file is mode $(mode_of "$KF"), not 600: another account could read it"
      [ "$(cat "$KF")" = "${as%:agents}" ] || fail "the agents' key file does not hold exactly the key bound to agents"
    else
      fail "the mint wrote no agents' key file for the operator to hand out"
    fi
    q "$S" "o['configmap/gateway-identity-map']['data']['identity.json']" >"$scratch/map.json" 2>/dev/null || : >"$scratch/map.json"
    python3 - "$scratch/map.json" acme.example <<'PY' || problems=$((problems + 1))
import json, sys
try:
    m = json.load(open(sys.argv[1]))
except Exception as e:
    print("FAIL: the minted ConfigMap does not hold a JSON identity map: %s" % e); sys.exit(1)
td = sys.argv[2]; felyx_id = "agent://%s/genaryx/felyx" % td
units = {u.get("id") for u in m.get("units", [])}
keys = {k.get("key_id"): k for k in m.get("keys", [])}
bad = []
if set(keys) != {"felyx", "agents", "drills", "broker", "costcrew"}:
    bad.append("the minted map binds key ids %s, not felyx, agents, drills, broker and costcrew" % sorted(keys))
elif (keys["drills"].get("agents") or []) != ["agent://mockryx.local/*"] or keys["drills"].get("unit") != "drills":
    bad.append("the minted map binds the drills' key to %s in unit %s, not agent://mockryx.local/* in unit drills" % (keys["drills"].get("agents"), keys["drills"].get("unit")))
elif (keys["broker"].get("agents") or []) != ["agent://%s/*" % td] or keys["broker"].get("unit") != "broker":
    bad.append("the minted map binds the broker's key to %s in unit %s, not exactly agent://%s/* in unit broker" % (keys["broker"].get("agents"), keys["broker"].get("unit"), td))
elif (keys["costcrew"].get("agents") or []) != ["agent://%s/costcrew/*" % td] or keys["costcrew"].get("unit") != "costcrew":
    bad.append("the minted map binds the CostCrew crew's key to %s in unit %s, not exactly agent://%s/costcrew/* in unit costcrew" % (keys["costcrew"].get("agents"), keys["costcrew"].get("unit"), td))
else:
    if keys["felyx"].get("agents") != [felyx_id]:
        bad.append("the minted map binds felyx to %s, not exactly [%s]" % (keys["felyx"].get("agents"), felyx_id))
    pats = keys["agents"].get("agents") or []
    if pats != ["agent://%s/agents/*" % td]:
        bad.append("the minted map binds the agents' key to %s, not [agent://%s/agents/*]" % (pats, td))
    for p in pats:
        if p == "*" or p == felyx_id or (p.endswith("*") and felyx_id.startswith(p[:-1])):
            bad.append("the agents' key may speak as Felyx: its pattern %s matches %s" % (p, felyx_id))
    for k in keys.values():
        if k.get("unit") not in units:
            bad.append("the minted map binds %s to unit %r, which it does not declare" % (k.get("key_id"), k.get("unit")))
if any("budget_usd_month" in u for u in m.get("units", [])) or m.get("prefixes"):
    bad.append("the minted map carries a budget or prefixes[]: it binds and attributes, and a budget is the operator's")
for b in bad:
    print("FAIL: " + b)
sys.exit(1 if bad else 0)
PY
    [ "$(q "$S" "o['configmap/gateway-identity-map']['data'].get('map_path')")" = /etc/tokenfuse/identity/identity.json ] \
      || fail "the minted ConfigMap's map_path is not the file inside the gateway's mount"
    sha="$(printf '%s' "$(cat "$scratch/map.json")" | { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1)"
    [ "$(q "$S" "o['deployment/tokenfuse-gateway']['spec']['template']['metadata'].get('annotations',{}).get('taipanbox.dev/identity-map-sha256')")" = "$sha" ] \
      || fail "the gateway's pod template does not carry the sha256 of the map, so verify.sh and identity/up.sh read it as not rolled"
    [ "$(q "$S" "o['deployment/tokenfuse-gateway']['spec']['template']['metadata'].get('annotations',{}).get('taipanbox.dev/client-keys-version')")" = "$(q "$S" "o['secret/gateway-client-keys']['metadata']['resourceVersion']")" ] \
      || fail "the gateway's pod template does not carry the version of the Secret it reads"
    [ "$(rolls "$S" tokenfuse-gateway)" = 1 ] || fail "the gateway was rolled $(rolls "$S" tokenfuse-gateway) time(s) on a first mint, not once"
    [ "$(rolls "$S" genaryx-console)" = 1 ] || fail "the console was rolled $(rolls "$S" genaryx-console) time(s) on a first mint, not once, so it keeps an empty Felyx key"
    if secret_in "$S" "$(cat "$S.calls")"; then fail "a minted secret was on a kubectl command line"; fi
    if secret_in "$S" "$out$(cat "$S.note")"; then fail "a minted secret appears in what the mint printed"; fi
    grep -qF "$KF" "$S.note" || fail "the closing note does not name the agents' key file, so the operator learns of the change from refused calls"
    grep -qF 'agent://acme.example/agents/' "$S.note" || fail "the closing note does not say which agent ids the key may speak as"
    grep -qF 'x-fuse-key' "$S.note" && grep -qF 'x-fuse-agent-id' "$S.note" || fail "the closing note does not name x-fuse-key and x-fuse-agent-id"

    # A re-run writes nothing, rolls nothing and keeps the file.
    w="$(nwrites "$S")"; cp "$KF" "$KF.before"
    out="$(settle "$S" "$KF")"
    [ "$(rc_of "$out")" = 0 ] || fail "a re-run of a minted cluster was refused: $(grep '^die' <<<"$out")"
    [ "$(nwrites "$S")" = "$w" ] || fail "a re-run of a minted cluster wrote to it, so it rewrites what it was asked to keep"
    cmp -s "$KF" "$KF.before" || fail "a re-run changed the agents' key file, so every agent holding the old key would be refused"
    [ "$(data_of "$S" secret/gateway-client-keys client_keys)" = "$spec" ] || fail "a re-run minted a new secret over the kept one"

    # A deleted key file and a deleted felyx-client-key come back with the same secret.
    rm -f "$KF"; drop "$S" secret/felyx-client-key; drop "$S" secret/drills-client-key; drop "$S" secret/broker-taint-key; drop "$S" secret/costcrew-client-key
    out="$(settle "$S" "$KF")"
    [ "$(cat "$KF" 2>/dev/null)" = "${as%:agents}" ] || fail "a deleted agents' key file did not come back with the same key"
    [ "$(data_of "$S" secret/felyx-client-key client_key)" = "$felyx" ] || fail "a deleted felyx-client-key did not come back with the key the Secret binds to felyx"
    [ "$(rolls "$S" genaryx-console)" = 2 ] || fail "a new felyx-client-key did not roll the console"
    [ "$(data_of "$S" secret/drills-client-key client_key)" = "${ds%:drills}" ] || fail "a deleted drills-client-key did not come back with the key the Secret binds to the drills"
    [ "$(data_of "$S" secret/broker-taint-key client_key)" = "${bk%:broker}" ] || fail "a deleted broker-taint-key did not come back with the key the Secret binds to the broker"
    [ "$(data_of "$S" secret/costcrew-client-key client_key)" = "${cc%:costcrew}" ] || fail "a deleted costcrew-client-key did not come back with the key the Secret binds to the CostCrew crew"

    # A moved trust domain rewrites the map alone and rolls the gateway.
    setdomain "$S" other.example
    out="$(settle "$S" "$KF")"
    grep -qF '"agent://other.example/genaryx/felyx"' <<<"$(q "$S" "o['configmap/gateway-identity-map']['data']['identity.json']")" \
      || fail "a moved trust domain did not rebind the minted map"
    [ "$(data_of "$S" secret/gateway-client-keys client_keys)" = "$spec" ] || fail "a moved trust domain rewrote the minted secrets"
    [ "$(rolls "$S" tokenfuse-gateway)" = 2 ] || fail "a rebound map did not roll the gateway, so it keeps the map it read at start"
  fi

  # The operator's own Secret: nothing written, no key file.
  S="$scratch/c2.json"; KF2="$scratch/agent-key-2"
  new_cluster "$S" acme.example
  put_keys "$S" "gate-operator-key-aaaaaaaaaaaaa:treasury" ""
  out="$(settle "$S" "$KF2")"
  [ "$(rc_of "$out")" = 0 ] && [ "$(nwrites "$S")" = 0 ] && [ ! -e "$KF2" ] \
    || fail "a cluster holding the operator's own keys was refused or written to by the mint: $(grep '^die' <<<"$out")"
  grep -qx 'minted=0' <<<"$out" || fail "a cluster holding the operator's own keys reports minted keys"

  refused() { # LABEL NEEDLE STATE
    local out
    out="$(settle "$3" "$scratch/agent-key-r")"
    if [ "$(rc_of "$out")" = 0 ]; then
      fail "$1 was accepted"
    elif ! grep -qF -- "$2" <<<"$out"; then
      fail "$1 was refused, but not saying: $2 ($(grep '^die' <<<"$out"))"
    fi
    [ "$(nwrites "$3")" = 0 ] || fail "$1 was refused after the cluster was written to"
    rm -f "$scratch/agent-key-r"
  }
  S="$scratch/c3.json"; new_cluster "$S" acme.example
  put "$S" configmap/gateway-identity-map '{"kind":"ConfigMap","metadata":{"name":"gateway-identity-map","resourceVersion":"8"},"data":{"identity.json":"{}","map_path":"/etc/tokenfuse/identity/identity.json"}}'
  refused "a map with no client keys" "has no client keys" "$S"
  S="$scratch/c4.json"; new_cluster "$S" acme.example
  put_keys "$S" "gate-aaaaaaaaaaaaaaaaaaaaaaaa:felyx,gate-bbbbbbbbbbbbbbbbbbbbbbbb:agents,gate-cccccccccccccccccccccccc:extra" minted
  refused "a minted Secret edited by hand" "edited by hand" "$S"
  S="$scratch/c5.json"; new_cluster "$S" 'a b'
  refused "a trust domain that is not a name" "not a name" "$S"

  # A cluster minted before the drills key: the two keys it holds are kept byte for byte,
  # the drills get their own, and the spec is patched on stdin, never rewritten.
  S="$scratch/c6.json"; new_cluster "$S" acme.example
  put_keys "$S" "gate-aaaaaaaaaaaaaaaaaaaaaaaa:felyx,gate-bbbbbbbbbbbbbbbbbbbbbbbb:agents" minted
  out="$(settle "$S" "$scratch/agent-key-m")"
  if [ "$(rc_of "$out")" != 0 ]; then
    fail "a minted cluster from before the drills key was refused by the mint: $(grep '^die' <<<"$out")"
  else
    m="$(data_of "$S" secret/gateway-client-keys client_keys)"
    [[ "$m" == gate-aaaaaaaaaaaaaaaaaaaaaaaa:felyx,gate-bbbbbbbbbbbbbbbbbbbbbbbb:agents,*:drills,*:broker,*:costcrew ]] \
      || fail "the migration changed the Felyx or the agents key, so both would be refused 401: $m"
    [[ "$m" =~ ,[A-Za-z0-9]{40}:drills,[A-Za-z0-9]{40}:broker,[A-Za-z0-9]{40}:costcrew$ ]] || fail "the migration did not add 40-character drills, broker and CostCrew keys"
  fi
fi

# ---- C. the gateway image reads the minted pair ---------------------------------------
if [ "$mint_ok" = 1 ] && [ -s "$scratch/c1.json" ] && [ -s "$scratch/map.json" ]; then
  if ! docker version >/dev/null 2>&1; then
    fail "no Docker here, so the gateway image could not read the minted pair. This gate does not pass on a box that cannot run it."
  else
    data_of "$scratch/c1.json" secret/gateway-client-keys client_keys | tr ',' '\n' >"$scratch/keys.txt"
    chmod 600 "$scratch/keys.txt"
    out="$(./identity/up.sh --check-only --client-keys-file "$scratch/keys.txt" --identity-map-file "$scratch/map.json" 2>&1)"
    rc=$?
    if [ "$rc" != 0 ]; then
      fail "the pinned gateway image refused the pair the mint made: $(grep -v '^$' <<<"$out" | tail -n 2 | tr '\n' ' ')"
    else
      grep -qF 'read 5 client key(s) and an identity map, and refused nothing' <<<"$out" \
        || fail "the pinned gateway image did not read five keys and the map from the minted pair: $(tail -n 2 <<<"$out" | tr '\n' ' ')"
    fi
  fi
fi

# ---- D. the order ---------------------------------------------------------------------
launchers="deploy.sh cloud/aws/deploy-aws.sh cloud/gcp/deploy-gcp.sh"
for f in $launchers; do
  if [ ! -f "$f" ]; then fail "$f is missing, so its mint step could not be judged"; continue; fi
  line_of() { grep -n -- "$1" "$f" | grep -v '^[0-9]*:[[:space:]]*#' | head -n 1 | cut -d: -f1; }
  src="$(line_of '^\. "\$ROOT/lib/identity-mint.sh" || die')"
  # The bracket keeps this line from reading as a deploy script to deploy-flags-agree.sh.
  apply="$(line_of '^k_ "apply -k /root/stack-k8s/manifest[s]"$')"
  td="$(line_of 'patch cm stack-wiring --type merge')"
  call="$(line_of '^identity_mint_settle "\$ROOT/agent-key"$')"
  wait_="$(line_of '^say "waiting for rollouts"$')"
  noteln="$(line_of '^identity_mint_note "\$ROOT/agent-key"$')"
  done_="$(line_of 'Done\.')"
  if [ -z "$src" ] || [ -z "$call" ] || [ -z "$noteln" ]; then
    fail "$f does not source lib/identity-mint.sh, call identity_mint_settle \"\$ROOT/agent-key\" and print identity_mint_note, so a cluster it deploys has a gateway that waits for keys nobody makes"
    continue
  fi
  if [ -z "$apply" ] || [ -z "$td" ] || [ -z "$wait_" ] || [ -z "$done_" ]; then
    fail "$f: could not find its apply, its trust-domain patch, its rollout wait or its closing report, so the mint's order is unknown"
    continue
  fi
  [ "$call" -gt "$apply" ] && [ "$call" -gt "$td" ] && [ "$call" -lt "$wait_" ] \
    || fail "$f calls the mint at line $call, not after its apply ($apply) and its trust-domain patch ($td) and before it waits for rollouts ($wait_): the keys would be bound to the wrong domain, or made after the wait gave up"
  [ "$noteln" -gt "$done_" ] || fail "$f prints the mint's note at line $noteln, before its closing report (line $done_)"
done
if ! grep -q '^identity_mint_settle "\$KEYFILE"$' identity/mint.sh 2>/dev/null; then
  fail "identity/mint.sh does not run the mint, so a cluster applied by hand has no way to its keys"
fi
grep -qx 'agent-key' .gitignore || fail ".gitignore does not cover agent-key, the file a deploy writes the agents' key to"
grep -q '"agent-key"' scripts/no-operator-files-tracked.sh || fail "scripts/no-operator-files-tracked.sh does not refuse a tracked agent-key"

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 50."
  exit 1
fi
echo "OK: every gateway requires gateway-client-keys and runs strict, the console reads Felyx's own key, and a"
echo "    deploy given no files mints the five keys, binds each to its own ids, keeps them on a re-run, rebinds"
echo "    the map alone when the trust domain moves, leaves the operator's keys alone, writes the agents' key"
echo "    to a 0600 file and names it, and the pinned gateway image reads the pair."
