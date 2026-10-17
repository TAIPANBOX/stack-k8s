#!/usr/bin/env bash
#
# Enforces invariant 39 of CLAUDE.md: the gateway's client keys and identity map
# come in as files, the pinned gateway image reads them before anything in the
# cluster changes, the keys live in a Secret and the map in a ConfigMap mounted
# read only, a re-run keeps both, and the gateway rolls exactly when what it
# reads has changed.
#
# WHAT THIS IS ABOUT
#
# tokenfuse's gateway can authenticate its callers (TOKENFUSE_CLIENT_KEYS,
# `secret:key_id,...`, presented as `x-fuse-key`) and bind each key to the agent
# ids it may speak as and the unit its spend lands in (TOKENFUSE_IDENTITY_MAP, a
# JSON file; tokenfuse docs/20). Both are off unless set, and both are easy to
# get silently wrong: an empty map reads as no map at all, a map key_id no secret
# carries can never match, a key the map does not bind is refused 403 on every
# call under the strict mode tokenfuse defaults to, and a TOKENFUSE_IDENTITY_MAP
# that names no file stops the gateway from starting. On a cluster two more
# things go wrong without a word: a ConfigMap or Secret change restarts nothing,
# so the gateway keeps what it read at start, and `kubectl apply -k` puts back
# whatever a manifest declares, so an operator's data must never be declared.
#
# WHAT THIS CHECKS
#
#   A. THE MANIFESTS. Every gateway start (the definition invariant 20 uses)
#      reads TOKENFUSE_CLIENT_KEYS from the Secret identity/up.sh writes, NOT
#      optional (invariant 50: the gateway requires keys, and a deploy given no
#      files mints them), and TOKENFUSE_IDENTITY_MAP from a key of the ConfigMap
#      that also carries the map, `optional: true`, so a cluster whose operator
#      brought keys and no map starts, and the path can never name a file that is
#      not there. The map is mounted read only from that ConfigMap, at the
#      directory up.sh names.
#      The command and the user are the ones up.sh gives its check container.
#      No other container names either object, and no manifest declares them.
#   B. THE FIRST HALF of identity/up.sh, `--check-only`, with a `docker` and a
#      `kubectl` on PATH that only record being run: a usable keys file is read
#      into the spec; every hostile or unusable file refuses, names the flag,
#      runs neither tool and never repeats a secret.
#   C. THE SECOND HALF, `--check-only` with the gateway image the manifest pins,
#      through a `docker` that records its arguments: a valid pair passes, the
#      gateway's own refusal and its three warnings refuse, an image with no
#      ENTRYPOINT works, and the check container has no network, the pod's user
#      and command, a read-only root, and no secret on its command line.
#   D. THE CLUSTER HALF, identity/up.sh against a stub `kubectl` that keeps the
#      objects in a file, with the real image check: a first run creates both
#      objects and rolls the gateway once; a re-run naming no file writes and
#      rolls nothing; the same map again rolls nothing; a new map and a new keys
#      file each write and roll once; a refused file writes nothing; no secret
#      is ever on a kubectl command line; a gateway that reports other keys than
#      it was given fails the run; a run that would leave no keys is refused;
#      on a cluster whose keys a deploy minted, one file alone is refused and
#      both together take the minted label off.
#   E. VERIFY. verify.sh asks the running gateway for a call with no key and
#      compares what the pod template says the gateway read with the objects.
#
# IDENTITY_SECTIONS=ABCDE (the default) chooses sections, so a teeth case can
# run the one its fault is about. CI and the hook run all five.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No gateway start, no identity/up.sh, no Docker or no gateway image: each is
# reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd -P)"

SECTIONS="${IDENTITY_SECTIONS:-ABCDE}"
want() { case "$SECTIONS" in *"$1"*) return 0 ;; esac; return 1; }

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

UP=identity/up.sh
if [ ! -f "$UP" ]; then
  echo "FAIL: identity/up.sh is missing, so this measured NOTHING about the client keys or the identity map."
  echo "      Silence here is not health."
  exit 1
fi
# The names, read from the script that writes the objects: the manifest and
# verify.sh are held to them, so the three cannot drift apart.
const() { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$UP" | head -n 1; }
SECRET_NAME="$(const SECRET_NAME)"
SECRET_KEY="$(const SECRET_KEY)"
MAP_CONFIGMAP="$(const MAP_CONFIGMAP)"
MAP_KEY="$(const MAP_KEY)"
MAP_PATH_KEY="$(const MAP_PATH_KEY)"
MAP_DIR="$(const MAP_DIR)"
GATEWAY_CMD="$(const GATEWAY_CMD)"
GATEWAY_USER="$(const GATEWAY_USER)"
ANN_MAP="$(const ANN_MAP)"
ANN_KEYS="$(const ANN_KEYS)"
for v in SECRET_NAME SECRET_KEY MAP_CONFIGMAP MAP_KEY MAP_PATH_KEY MAP_DIR GATEWAY_CMD GATEWAY_USER ANN_MAP ANN_KEYS; do
  if [ -z "${!v}" ]; then
    echo "FAIL: identity/up.sh sets no $v, so this gate cannot tell what it writes. It measured NOTHING."
    exit 1
  fi
done
export SECRET_NAME SECRET_KEY MAP_CONFIGMAP MAP_KEY MAP_PATH_KEY MAP_DIR GATEWAY_CMD GATEWAY_USER ANN_MAP ANN_KEYS

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# ---- A. the manifests ------------------------------------------------------------
# The reader is written to a file and run from there, not fed to python3 inside
# "$(...)": bash 3.2 counts the quotes of a heredoc inside a command substitution,
# and the apostrophes in its messages end it early (GOTCHAS 71).
IMG=""
if want A || want C || want D; then
  cat >"$scratch/a.py" <<'PY'
import os
import pathlib
import re
import sys

E = os.environ
SECRET, SKEY = E["SECRET_NAME"], E["SECRET_KEY"]
CM, MKEY, PKEY = E["MAP_CONFIGMAP"], E["MAP_KEY"], E["MAP_PATH_KEY"]
MAP_DIR, CMD, USER = E["MAP_DIR"], E["GATEWAY_CMD"], E["GATEWAY_USER"]

POD_TEMPLATE_KINDS = {
    "Deployment":  ["spec", "template", "spec"],
    "StatefulSet": ["spec", "template", "spec"],
    "Job":         ["spec", "template", "spec"],
    "CronJob":     ["spec", "jobTemplate", "spec", "template", "spec"],
}
IMAGE_RE = re.compile(r'^\s*image:\s*"?((?:[^\s"]*/)?tokenfuse:[^\s"]+)', re.M)
ARGS_RE = re.compile(r'^\s*args:', re.M)
COMMAND_FLOW_RE = re.compile(r'^\s*command:\s*\[(.*)\]\s*$', re.M)
COMMAND_BLOCK_RE = re.compile(r'^\s*command:\s*$', re.M)


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def blank_or_comment(line):
    s = line.strip()
    return s == "" or s.startswith("#")


def live(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


def block_end(lines, idx, indent):
    j = idx + 1
    while j < len(lines):
        if not blank_or_comment(lines[j]) and indent_of(lines[j]) <= indent:
            return j
        j += 1
    return len(lines)


def find_child(lines, start, end, key, indent):
    for j in range(start, end):
        line = lines[j]
        if blank_or_comment(line):
            continue
        if indent_of(line) < indent:
            return None
        if indent_of(line) == indent and line.strip() == key + ":":
            return j
    return None


def locate(lines, kind_idx, path):
    start, end, indent, idx = kind_idx, len(lines), -2, None
    for key in path:
        indent += 2
        idx = find_child(lines, start, end, key, indent)
        if idx is None:
            return None
        start, end = idx + 1, block_end(lines, idx, indent)
    return idx, indent


def items(lines, header_idx, header_indent):
    """The `- ` items of the list under a header, as (start, end) line ranges."""
    end = block_end(lines, header_idx, header_indent)
    item_indent = None
    for j in range(header_idx + 1, end):
        if not blank_or_comment(lines[j]) and lines[j].lstrip().startswith("- "):
            item_indent = indent_of(lines[j])
            break
    if item_indent is None:
        return []
    starts = [j for j in range(header_idx + 1, end)
              if not blank_or_comment(lines[j]) and indent_of(lines[j]) == item_indent
              and lines[j].lstrip().startswith("- ")]
    return [(s, starts[i + 1] if i + 1 < len(starts) else end) for i, s in enumerate(starts)]


def is_serve_start(text):
    if not IMAGE_RE.search(text) or ARGS_RE.search(text):
        return False
    if COMMAND_BLOCK_RE.search(text):
        return True
    m = COMMAND_FLOW_RE.search(text)
    if not m:
        return True
    argv = [p.strip().strip("\"'") for p in m.group(1).split(",") if p.strip()]
    return len(argv) == 1 and argv[0].rsplit("/", 1)[-1] == "tokenfuse"


def fields(text, ref):
    """name/key/optional of a `<ref>: { ... }` in flow or block form."""
    m = re.search(ref + r':\s*\{([^}]*)\}', text)
    body = m.group(1) if m else None
    if body is None:
        m = re.search(ref + r':\s*\n((?:\s+\S.*\n?)+)', text)
        body = m.group(1) if m else None
    if body is None:
        return None
    out = {}
    for k in ("name", "key", "optional"):
        mm = re.search(r'\b' + k + r':\s*"?([^",}\s]+)"?', body)
        out[k] = mm.group(1) if mm else None
    return out


def env_entries(lines, c_start, c_end, name):
    """The live text of each env item that names `name`, in this container."""
    out = []
    for j in range(c_start, c_end):
        if blank_or_comment(lines[j]):
            continue
        if re.search(r'(^|[\s{,-])name:\s*' + re.escape(name) + r'\s*([,}]|$)', lines[j]):
            ind = indent_of(lines[j])
            k = j + 1
            while k < c_end and (blank_or_comment(lines[k]) or indent_of(lines[k]) > ind):
                k += 1
            out.append(live("\n".join(lines[j:k])))
    return out


problems = []
subjects = 0
image = None
docs_seen = 0
for path in sorted(pathlib.Path("manifests").glob("*.yaml")):
    raw = path.read_text().split("\n")
    docs, cur = [], []
    for line in raw:
        if line.strip() == "---":
            docs.append(cur)
            cur = []
        else:
            cur.append(line)
    docs.append(cur)
    for lines in docs:
        text = "\n".join(lines)
        livetext = live(text)
        kind_m = re.search(r'^kind:\s*(\S+)', livetext, re.M)
        kind = kind_m.group(1) if kind_m else None
        docs_seen += 1
        if kind in ("Secret", "ConfigMap") and re.search(
                r'^\s*name:\s*"?(' + re.escape(SECRET) + "|" + re.escape(CM) + r')"?\s*$', livetext, re.M):
            problems.append(f"{path} declares the {kind} the operator's files live in. `kubectl apply -k` "
                            "and every deploy would put the manifest's copy back over the operator's keys or map.")
        if kind not in POD_TEMPLATE_KINDS:
            continue
        kind_idx = next(i for i, l in enumerate(lines) if l.startswith("kind:"))
        loc = locate(lines, kind_idx, POD_TEMPLATE_KINDS[kind])
        if loc is None:
            continue
        pod_idx, pod_ind = loc
        pod_end = block_end(lines, pod_idx, pod_ind)
        name_m = re.search(r'^metadata:\s*\n\s+name:\s*(\S+)|^metadata:\s*\{\s*name:\s*([^,}\s]+)', livetext, re.M)
        wname = (name_m.group(1) or name_m.group(2)) if name_m else "?"
        ci = find_child(lines, pod_idx + 1, pod_end, "containers", pod_ind + 2)
        conts = items(lines, ci, pod_ind + 2) if ci is not None else []
        vi = find_child(lines, pod_idx + 1, pod_end, "volumes", pod_ind + 2)
        vols = items(lines, vi, pod_ind + 2) if vi is not None else []
        vol_text = {}
        for s, e in vols:
            t = live("\n".join(lines[s:e]))
            m = re.search(r'name:\s*([A-Za-z0-9-]+)', t)
            if m:
                vol_text[m.group(1)] = t
        sec = live("\n".join(lines[pod_idx:pod_end]))
        for s, e in conts:
            ctext = "\n".join(lines[s:e])
            clive = live(ctext)
            cname_m = re.search(r'name:\s*([A-Za-z0-9-]+)', clive)
            cname = cname_m.group(1) if cname_m else "?"
            mounted = re.findall(r'\{\s*name:\s*([A-Za-z0-9-]+)\s*,\s*mountPath:', clive)
            mounted += re.findall(r'-\s*name:\s*([A-Za-z0-9-]+)\s*\n\s*mountPath:', clive)
            uses_cm_vol = [v for v in mounted if v in vol_text and re.search(r'\b' + re.escape(CM) + r'\b', vol_text[v])]
            if not is_serve_start(clive):
                if re.search(r'\b(' + re.escape(SECRET) + "|" + re.escape(CM) + r')\b', clive) or uses_cm_vol:
                    problems.append(f"{path} {wname}/{cname} names {SECRET} or {CM}. The client keys and the "
                                    "map are the gateway's; another container holding them is another place they leak from.")
                continue
            subjects += 1
            where = f"{path} {wname}/{cname}"
            im = IMAGE_RE.search(clive)
            image = image or (im.group(1) if im else None)
            # the client keys, from the Secret, required (invariant 50)
            ents = env_entries(lines, s, e, "TOKENFUSE_CLIENT_KEYS")
            if not ents:
                problems.append(f"{where} sets no TOKENFUSE_CLIENT_KEYS, so the Secret identity/up.sh writes never reaches it.")
            elif len(ents) > 1:
                problems.append(f"{where} sets TOKENFUSE_CLIENT_KEYS {len(ents)} times, and the later entry wins without a word.")
            else:
                f = fields(ents[0], "secretKeyRef")
                if f is None or re.search(r'\bvalue:', ents[0]):
                    problems.append(f"{where} sets TOKENFUSE_CLIENT_KEYS other than from a secretKeyRef, so the keys "
                                    "are in the manifest or nowhere.")
                elif (f["name"], f["key"]) != (SECRET, SKEY):
                    problems.append(f"{where} reads TOKENFUSE_CLIENT_KEYS from {f['name']}/{f['key']}, not "
                                    f"{SECRET}/{SKEY}, which is what identity/up.sh writes.")
                elif f["optional"] == "true":
                    problems.append(f"{where} reads TOKENFUSE_CLIENT_KEYS from {SECRET} optional, so a cluster "
                                    "with no Secret starts a gateway that answers every caller (invariant 50).")
            # the map path, from the map's own ConfigMap, optional
            ents = env_entries(lines, s, e, "TOKENFUSE_IDENTITY_MAP")
            if not ents:
                problems.append(f"{where} sets no TOKENFUSE_IDENTITY_MAP, so the map identity/up.sh writes is never read.")
            elif len(ents) > 1:
                problems.append(f"{where} sets TOKENFUSE_IDENTITY_MAP {len(ents)} times, and the later entry wins without a word.")
            else:
                f = fields(ents[0], "configMapKeyRef")
                if f is None or re.search(r'\bvalue:', ents[0]):
                    problems.append(f"{where} sets TOKENFUSE_IDENTITY_MAP not read from the map's own ConfigMap. A "
                                    "literal path names a file that is not there on a cluster with no map, and the "
                                    "gateway refuses to start on it.")
                elif (f["name"], f["key"]) != (CM, PKEY):
                    problems.append(f"{where} reads TOKENFUSE_IDENTITY_MAP from {f['name']}/{f['key']}, not {CM}/{PKEY}.")
                elif f["optional"] != "true":
                    problems.append(f"{where} reads TOKENFUSE_IDENTITY_MAP from {CM} not optional, so a cluster that "
                                    "names no map keeps its gateway in CreateContainerConfigError.")
            # the mount: read only, at MAP_DIR, from the map's ConfigMap
            mount_lines = [j for j in range(s, e) if not blank_or_comment(lines[j])
                           and re.search(r'mountPath:\s*"?' + re.escape(MAP_DIR) + r'"?\s*([,}]|$)', lines[j])]
            if not mount_lines:
                problems.append(f"{where} mounts nothing at {MAP_DIR}, so the map identity/up.sh writes is not "
                                "the map it reads.")
            else:
                j = mount_lines[0]
                k0 = j
                while k0 > s and not lines[k0].lstrip().startswith("- "):
                    k0 -= 1
                k1 = k0 + 1
                while k1 < e and not lines[k1].lstrip().startswith("- ") and not blank_or_comment(lines[k1]) \
                        and indent_of(lines[k1]) > indent_of(lines[k0]):
                    k1 += 1
                mtext = live("\n".join(lines[k0:max(k1, j + 1)]))
                ro = re.search(r'readOnly:\s*(\S+?)\s*[,}\n]', mtext + "\n")
                vn = re.search(r'name:\s*([A-Za-z0-9-]+)', mtext)
                if not ro or ro.group(1) != "true":
                    problems.append(f"{where} mounts {MAP_DIR} not read only. The gateway reads the map and must "
                                    "not be able to change it.")
                vt = vol_text.get(vn.group(1)) if vn else None
                if vt is None:
                    problems.append(f"{where} mounts {MAP_DIR} from a volume this pod does not declare.")
                else:
                    f = fields(vt, "configMap")
                    if f is None or f["name"] != CM:
                        problems.append(f"{where} mounts {MAP_DIR} from something other than the {CM} ConfigMap.")
                    elif f["optional"] != "true":
                        problems.append(f"{where} mounts the {CM} ConfigMap not optional, so a cluster that names no "
                                        "map keeps its gateway from starting.")
                    keys = re.findall(r'key:\s*"?([^",}\s]+)', vt)
                    paths = re.findall(r'path:\s*"?([^",}\s]+)', vt)
                    if keys != [MKEY] or paths != [MKEY]:
                        problems.append(f"{where} projects {keys or 'every key'} of {CM}, not exactly {MKEY}: the "
                                        "path key or a stray key would sit beside the map in the gateway's directory.")
            # the command and the user the check container copies
            m = COMMAND_FLOW_RE.search(clive)
            argv = [p.strip().strip("\"'") for p in m.group(1).split(",")] if m else []
            if argv != [CMD]:
                problems.append(f"{where} runs {argv or 'the image entrypoint'}, not [{CMD}], which is the command "
                                "identity/up.sh gives the container that reads the files first.")
            ru = re.search(r'runAsUser:\s*(\d+)', sec)
            rg = re.search(r'runAsGroup:\s*(\d+)', sec)
            if not ru or not rg or f"{ru.group(1)}:{rg.group(1)}" != USER:
                problems.append(f"{where} runs as {ru.group(1) if ru else '?'}:{rg.group(1) if rg else '?'}, not "
                                f"{USER}, the user identity/up.sh checks the files as.")

if docs_seen == 0 or subjects == 0:
    print("FAIL: no container under manifests/ runs the tokenfuse gateway with no subcommand, so this gate")
    print("      measured NOTHING about client keys or the identity map. Silence here is not health.")
    sys.exit(1)
for p in problems:
    print("FAIL: " + p)
if problems:
    sys.exit(1)
print(f"IMAGE={image}")
print(f"manifest: {subjects} gateway start(s) read the client keys (required) and the map (optional), map mounted read only")
PY
  a_out="$(python3 "$scratch/a.py")"
  a_rc=$?
  IMG="$(printf '%s\n' "$a_out" | sed -n 's/^IMAGE=//p' | head -n 1)"
  if want A; then
    printf '%s\n' "$a_out" | grep -v '^IMAGE=' | grep '^FAIL\|^      ' || true
    [ "$a_rc" = 0 ] || problems=$((problems + 1))
  fi
  if [ -z "$IMG" ]; then
    IMG="$(grep -h -o 'ghcr\.io/taipanbox/tokenfuse:v[0-9][^ "]*' manifests/10-planes.yaml | head -n 1)"
  fi
fi

# ---- the operator's files, for B, C and D ---------------------------------------------
op="$scratch/op"   # where the operator stands
bin="$scratch/bin" # stand-ins on PATH
mkdir -p "$op" "$bin"

K1="gate-secret-aaaaaaaaaaaaaaaaaaaaaa1"
K2="gate-secret-bbbbbbbbbbbbbbbbbbbbbb2"
K3="gate-secret-cccccccccccccccccccccc3"
KT="gate-secret-tilde:~:dddddddddddddd4"
printf '# a comment: with a colon\r\n%s:treasury-bots\r\n\n   %s:research-bots   \n' "$K1" "$K2" >"$op/keys.txt"
printf '%s:treasury-bots\n%s:research-bots\n%s:treasury-bots\n' "$K1" "$K2" "$K3" >"$op/keys3.txt"
printf '%s:treasury-bots\n' "$K1" >"$op/keys-treasury-only.txt"
printf '%s:treasury-bots\n%s:research-bots\n%s:orphan\n' "$K1" "$K2" "$K3" >"$op/keys-orphan.txt"
printf '%s:tilde-bot\n' "$KT" >"$op/keys-tilde.txt"
SPEC2="$K1:treasury-bots,$K2:research-bots"
SPEC3="$K1:treasury-bots,$K2:research-bots,$K3:treasury-bots"
cat >"$op/map.json" <<'JSON'
{
  "units": [
    {"id": "treasury", "name": "Treasury", "budget_usd_month": 20},
    {"id": "research", "budget_usd_month": 5}
  ],
  "keys": [
    {"key_id": "treasury-bots", "unit": "treasury", "agents": ["agent://bank.example/treasury/*"]},
    {"key_id": "research-bots", "unit": "research", "agents": ["agent://bank.example/research/*"]}
  ]
}
JSON
sed 's/"budget_usd_month": 5}/"budget_usd_month": 7}/' "$op/map.json" >"$op/map2.json"
printf '{}\n' >"$op/map-empty-object.json"
printf '{"units":[{"id":"a"}],"keys":[{"key_id":"treasury-bots","unit":"nope"}]}\n' >"$op/map-unknown-unit.json"
printf '{"units":[{"id":"fleet"}],"prefixes":[{"match":"agent://bank.example/*","unit":"fleet"}]}\n' >"$op/map-prefixes.json"
printf '{"units":[{"id":"tilde"}],"keys":[{"key_id":"tilde-bot","unit":"tilde"}]}\n' >"$op/map-tilde.json"
sha_of() { python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -n 1; }
has_secret() { grep -qF -e "$K1" -e "$K2" -e "$K3" -e "$KT" -e 'gate-secret-' <<<"$1"; }

# ---- B. the first half: grammar, before any tool runs -------------------------------
if want B; then
  # Stand-ins that only record being run. The docker one also keeps the spec it
  # was handed through its environment, which is how the first half's reading of
  # a usable file is seen without running anything.
  bbin="$scratch/bbin"
  mkdir -p "$bbin"
  cat >"$bbin/docker" <<'SH'
#!/bin/sh
touch "$GATE_RAN.docker"
case "$1" in
  run) printf '%s' "${TOKENFUSE_CLIENT_KEYS:-}" >"$GATE_RAN.spec"; exit 1 ;;
esac
exit 0
SH
  cat >"$bbin/kubectl" <<'SH'
#!/bin/sh
touch "$GATE_RAN.kubectl"
exit 1
SH
  chmod +x "$bbin/docker" "$bbin/kubectl"
  brun() { # marker args...: identity/up.sh --check-only from the operator's directory
    local mark="$1"
    shift
    (cd "$op" && env -i PATH="$bbin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$scratch" GATE_RAN="$mark" \
      IDENTITY_IMAGE=gate-image-not-pulled "$ROOT/$UP" --check-only "$@"; printf 'rc=%s\n' "$?") 2>&1
  }
  m="$scratch/b-ok"
  out="$(brun "$m" --client-keys-file keys.txt --identity-map-file map.json)"
  if [ ! -e "$m.docker" ]; then
    fail "a usable keys file (a comment, a blank line, CRLF, surrounding spaces) and map, named relative to where the operator stands, never reached the gateway image: $(grep -v '^rc=' <<<"$out" | tail -n 2)"
  elif [ "$(cat "$m.spec")" != "$SPEC2" ]; then
    fail "the keys file was not read as its two secret:key_id lines, in order and trimmed"
  fi
  refuses() { # label flag file [secret that must not be echoed]
    local label="$1" flag="$2" file="$3" secret="${4:-}" mk out
    mk="$scratch/b-$(printf '%s' "$label$flag" | cksum | cut -d' ' -f1)"
    out="$(brun "$mk" "$flag" "$file")"
    if [ "$(rc_of "$out")" = 0 ]; then
      fail "$flag ($label) was accepted"
    elif ! grep -qF -- "$flag" <<<"$out"; then
      fail "$flag ($label) was refused without naming the flag: $(grep -v '^rc=' <<<"$out" | tail -n 1)"
    fi
    if [ -e "$mk.docker" ] || [ -e "$mk.kubectl" ]; then
      fail "$flag ($label) reached docker or kubectl before it was refused, which is the order this exists to prevent"
    fi
    if [ -n "$secret" ] && grep -qF -- "$secret" <<<"$out"; then
      fail "$flag ($label) was refused by an answer that repeats the secret"
    fi
  }
  kf() { printf "$@" >"$op/k.case.$n"; printf 'k.case.%s' "$n"; n=$((n + 1)); }
  n=0
  long="$(printf 'a%.0s' $(seq 1 257))"
  refuses "a line with no colon" --client-keys-file "$(kf 'gate-secret-nocolon-aaaaaaaaaaaaa\n')" gate-secret-nocolon-aaaaaaaaaaaaa
  refuses "an empty key id" --client-keys-file "$(kf '%s:\n' "$K1")" "$K1"
  refuses "a key id with a space" --client-keys-file "$(kf '%s:treasury bots\n' "$K1")" "$K1"
  refuses "a key id with a comma" --client-keys-file "$(kf '%s:a,b\n' "$K1")" "$K1"
  refuses "a key id of 129 characters" --client-keys-file "$(kf '%s:%s\n' "$K1" "${long:0:129}")" "$K1"
  refuses "a secret of 23 characters" --client-keys-file "$(kf 'gate-secret-23-charsxxx:k\n')" gate-secret-23-charsxxx
  refuses "a secret of 257 characters" --client-keys-file "$(kf '%s:k\n' "$long")" "$long"
  refuses "a secret with a space" --client-keys-file "$(kf 'gate-secret with-a-space-aaaaaaa:k\n')" "gate-secret with-a-space-aaaaaaa"
  refuses "a secret with a quote" --client-keys-file "$(kf "gate-secret-'quote'-aaaaaaaaaaa:k\n")" "gate-secret-'quote'-aaaaaaaaaaa"
  refuses "a secret with a dollar" --client-keys-file "$(kf 'gate-secret-$(touch pwned-by-identity)-a:k\n')" 'gate-secret-$(touch pwned-by-identity)-a'
  refuses "a secret with a backtick" --client-keys-file "$(kf 'gate-secret-`touch pwned-by-identity`-aa:k\n')" 'gate-secret-`touch pwned-by-identity`-aa'
  refuses "a secret given twice" --client-keys-file "$(kf '%s:a\n%s:b\n' "$K1" "$K1")" "$K1"
  refuses "comments and blank lines only" --client-keys-file "$(kf '# nothing here\n\n   \n')"
  refuses "an empty file" --client-keys-file "$(kf '')"
  refuses "a path that names nothing" --client-keys-file "no-such-keys-file"
  refuses "a directory" --client-keys-file "."
  refuses "a NUL byte" --client-keys-file "$(kf '%s:treasury-bots\n\0\n' "$K1")" "$K1"
  head -c 262145 /dev/zero | tr '\0' 'a' >"$op/keys-huge"
  refuses "a file over 256 KiB" --client-keys-file keys-huge
  if [ -e "$op/pwned-by-identity" ] || [ -e "$scratch/pwned-by-identity" ]; then
    fail "a command in a keys file was executed"
  fi
  refuses "a path that names nothing" --identity-map-file "no-such-map.json"
  refuses "a directory" --identity-map-file "."
  refuses "an empty file" --identity-map-file "$(kf '   \n')"
  refuses "a JSON array, not an object" --identity-map-file "$(kf '[{"units": []}]\n')"
  refuses "a NUL byte" --identity-map-file "$(kf '{"units": []}\0\n')"
  refuses "bytes that are not UTF-8" --identity-map-file "$(kf '{"units": [{"id": "\377"}]}\n')"
  { printf '{'; head -c 1044480 /dev/zero | tr '\0' ' '; printf '}'; } >"$op/map-huge.json"
  refuses "a map larger than a ConfigMap holds" --identity-map-file map-huge.json
  out="$(brun "$scratch/b-none")"
  [ "$(rc_of "$out")" != 0 ] || fail "--check-only with no file at all reported success, on nothing"
fi

# ---- a docker that records its arguments, for C and D ------------------------------------
REAL_DOCKER="$(command -v docker || true)"
docker_ok=0
if want C || want D; then
  if [ -z "$REAL_DOCKER" ] || ! docker version >/dev/null 2>&1; then
    fail "no Docker here, so the gateway image could not read anything. This gate does not pass on a machine that cannot run it."
  elif [ -z "$IMG" ]; then
    fail "the manifests name no tokenfuse gateway image, so the second half could not be run"
  elif ! docker image inspect "$IMG" >/dev/null 2>&1 && ! docker pull -q "$IMG" >/dev/null 2>&1; then
    fail "could not pull $IMG, so the second half could not be run"
  else
    docker_ok=1
  fi
  cat >"$bin/docker" <<SH
#!/bin/sh
# Records every argument, one call per line, then runs the real docker.
printf '%s\n' "\$*" >>"\${GATE_DOCKER_LOG:-/dev/null}"
exec "$REAL_DOCKER" "\$@"
SH
  chmod +x "$bin/docker"
fi

# ---- C. the second half, the gateway image itself ------------------------------------------
NOENT="stack-k8s-gate/tokenfuse-no-entrypoint:local"
if want C && [ "$docker_ok" = 1 ]; then
  crun() { # log args...
    local log="$1"
    shift
    (cd "$op" && env -i PATH="$bin:$PATH" HOME="$HOME" GATE_DOCKER_LOG="$log" \
      "$ROOT/$UP" --check-only "$@"; printf 'rc=%s\n' "$?") 2>&1
  }
  c_ok() { # label needle args...
    local label="$1" needle="$2" log out
    shift 2
    log="$scratch/c.$(printf '%s' "$label" | cksum | cut -d' ' -f1).log"
    out="$(crun "$log" "$@")"
    if [ "$(rc_of "$out")" != 0 ]; then
      echo "FAIL: $label was refused by the second half: $(grep -v '^rc=' <<<"$out" | tail -n 2 | tr '\n' ' ')"
    elif ! grep -qF -- "$needle" <<<"$out"; then
      echo "FAIL: $label passed without saying: $needle"
    fi
    if has_secret "$out"; then echo "FAIL: $label printed a secret"; fi
    if [ -s "$log" ] && has_secret "$(cat "$log")"; then
      echo "FAIL: $label put a secret on the docker command line, where the process table shows it"
    fi
    if ! grep -q -- '--network none' "$log" 2>/dev/null; then
      echo "FAIL: $label ran the check container with a network: it must reach nothing"
    fi
    if ! grep -q -- "--entrypoint $GATEWAY_CMD" "$log" 2>/dev/null; then
      echo "FAIL: $label ran the check container without the gateway's own command, $GATEWAY_CMD"
    fi
    if ! grep -q -- "--user $GATEWAY_USER" "$log" 2>/dev/null || ! grep -q -- '--read-only' "$log" 2>/dev/null; then
      echo "FAIL: $label ran the check container as someone kinder than the pod: not $GATEWAY_USER with a read-only root"
    fi
  }
  c_refused() { # label needle args...
    local label="$1" needle="$2" out
    shift 2
    out="$(crun /dev/null "$@")"
    if [ "$(rc_of "$out")" = 0 ]; then
      echo "FAIL: $label was accepted"
    elif ! grep -qF -- "$needle" <<<"$out"; then
      echo "FAIL: $label was refused, but not saying: $needle ($(grep -v '^rc=' <<<"$out" | tail -n 1))"
    fi
    if has_secret "$out"; then echo "FAIL: $label was refused by an answer that repeats a secret"; fi
  }
  c_ok "a valid keys file and map" "2 client key(s) and an identity map" \
    --client-keys-file keys.txt --identity-map-file map.json >"$scratch/c.1" 2>&1 &
  c_ok "a secret holding :~:, keys and its map" "1 client key(s) and an identity map" \
    --client-keys-file keys-tilde.txt --identity-map-file map-tilde.json >"$scratch/c.2" 2>&1 &
  c_ok "a map of units and prefixes alone, with no keys" "0 client key(s) and an identity map" \
    --identity-map-file map-prefixes.json >"$scratch/c.3" 2>&1 &
  c_refused "a map that binds a key id no client key carries" "research-bots that no client key carries" \
    --client-keys-file keys-treasury-only.txt --identity-map-file map.json >"$scratch/c.4" 2>&1 &
  c_refused "a client key the map does not bind" "orphan have no keys[] binding" \
    --client-keys-file keys-orphan.txt --identity-map-file map.json >"$scratch/c.5" 2>&1 &
  c_refused "a map that configures nothing ({})" "configures nothing" \
    --client-keys-file keys.txt --identity-map-file map-empty-object.json >"$scratch/c.6" 2>&1 &
  c_refused "a map naming a unit it does not declare" "not declared in units[]" \
    --client-keys-file keys.txt --identity-map-file map-unknown-unit.json >"$scratch/c.7" 2>&1 &
  c_refused "a map with key bindings and no client keys at all" "that no client key carries" \
    --identity-map-file map.json >"$scratch/c.8" 2>&1 &
  # The image BUILD_FROM_SOURCE builds has no ENTRYPOINT (images/tokenfuse.Dockerfile),
  # so the check has to give the command the manifest gives the gateway.
  if printf 'FROM %s\nENTRYPOINT []\n' "$IMG" | docker build -q -t "$NOENT" - >/dev/null 2>&1; then
    c_ok "a gateway image with no ENTRYPOINT, the shape BUILD_FROM_SOURCE builds" "2 client key(s) and an identity map" \
      --image "$NOENT" --client-keys-file keys.txt --identity-map-file map.json >"$scratch/c.9" 2>&1 &
  else
    echo "FAIL: could not build a no-ENTRYPOINT image from $IMG, so the BUILD_FROM_SOURCE shape was not checked" >"$scratch/c.9"
  fi
  wait
  for f in "$scratch"/c.[0-9]*; do
    while IFS= read -r line; do
      case "$line" in FAIL:*) printf '%s\n' "$line"; problems=$((problems + 1)) ;; esac
    done <"$f"
  done
fi

# ---- D. the cluster half, against a stub kubectl ----------------------------------------
if want D && [ "$docker_ok" = 1 ]; then
  cat >"$bin/kubectl" <<'PY'
#!/usr/bin/env python3
# A stub API server for the calls identity/up.sh makes, and nothing else: an
# unknown call fails loudly, so a changed script is noticed rather than faked.
import base64, copy, json, os, sys
argv = sys.argv[1:]
with open(os.environ["STUB_CALLS"], "a") as f:
    f.write(json.dumps(argv) + "\n")
a, i = [], 0
while i < len(argv):
    if argv[i] in ("-n", "--namespace"):
        i += 2
        continue
    a.append(argv[i])
    i += 1
st = json.load(open(os.environ["STUB_STATE"]))
KIND = {"secret": "Secret", "configmap": "ConfigMap"}


def save():
    json.dump(st, open(os.environ["STUB_STATE"], "w"))


def die(msg, code=97):
    sys.stderr.write("stub kubectl: " + msg + ": " + " ".join(argv) + "\n")
    sys.exit(code)


def merge(x, y):
    for k, v in y.items():
        if v is None:
            x.pop(k, None)
        elif isinstance(v, dict) and isinstance(x.get(k), dict):
            merge(x[k], v)
        else:
            x[k] = copy.deepcopy(v)


def bump():
    st["rv"] += 1
    return str(st["rv"])


def gateway_log():
    out = []
    s = st.get("secret")
    if s and s.get("data", {}).get(os.environ["SECRET_KEY"]):
        spec = base64.b64decode(s["data"][os.environ["SECRET_KEY"]]).decode()
        n = len([e for e in spec.split(",") if e]) + (1 if os.environ.get("STUB_LOGS_LIE") else 0)
        out.append("client auth: ON (%d key(s)); metered calls must send the `x-fuse-key` header" % n)
    c = st.get("configmap")
    if c and c.get("data", {}).get(os.environ["MAP_KEY"]):
        out.append("identity map: ON (2 unit(s), 2 key binding(s)); strict=Enforce")
    out.append("tokenfuse gateway listening addr=0.0.0.0:4100")
    return "\n".join(out) + "\n"


def roll():
    st["rollouts"] += 1
    ann = st["deployment"]["spec"]["template"]["metadata"].get("annotations", {})
    st["pods"] = [{"metadata": {"name": "gateway-%d" % st["rollouts"], "annotations": copy.deepcopy(ann),
                                "creationTimestamp": "2026-10-13T10:%02d:00Z" % st["rollouts"]},
                   "status": {"phase": "Running"}, "log": gateway_log()}]


if a[:1] == ["version"]:
    print("{}")
elif a[:2] == ["get", "namespace"] and len(a) >= 3:
    print("namespace/" + a[2])
elif a[:3] == ["get", "deployment", "tokenfuse-gateway"] and "json" in a:
    print(json.dumps(st["deployment"]))
elif a[:2] in (["get", "secret"], ["get", "configmap"]) and "json" in a:
    o = st.get(a[1])
    if o is None or o["metadata"]["name"] != a[2]:
        if "--ignore-not-found" in a:
            sys.exit(0)
        die("NotFound", 1)
    print(json.dumps(o))
elif a == ["create", "-f", "-"]:
    o = json.load(sys.stdin)
    k = o.get("kind", "").lower()
    if k not in KIND:
        die("create of an unexpected kind")
    if st.get(k) is not None:
        die("AlreadyExists", 1)
    o["metadata"]["resourceVersion"] = bump()
    st[k] = o
    st["writes"].append(["create", k])
    save()
elif a[:3] == ["create", "secret", "generic"]:
    o = {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": a[3]}, "data": {}}
    for x in a[4:]:
        if x.startswith("--from-literal="):
            k, v = x[len("--from-literal="):].split("=", 1)
            o["data"][k] = base64.b64encode(v.encode()).decode()
        elif x.startswith("--from-file="):
            k, p = x[len("--from-file="):].split("=", 1)
            o["data"][k] = base64.b64encode(open(p, "rb").read()).decode()
    if st.get("secret") is not None:
        die("AlreadyExists", 1)
    o["metadata"]["resourceVersion"] = bump()
    st["secret"] = o
    st["writes"].append(["create", "secret"])
    save()
elif a[:1] == ["patch"] and len(a) >= 3 and "--type" in a and a[a.index("--type") + 1] == "merge":
    k, name = a[1], a[2]
    if "--patch-file" in a:
        body = json.load(open(a[a.index("--patch-file") + 1]))
    elif "-p" in a:
        body = json.loads(a[a.index("-p") + 1])
    else:
        die("patch with no body")
    if k in KIND:
        o = st.get(k)
        if o is None or o["metadata"]["name"] != name:
            die("NotFound", 1)
        before = json.dumps(o, sort_keys=True)
        merge(o, body)
        if json.dumps(o, sort_keys=True) != before:
            o["metadata"]["resourceVersion"] = bump()
            st["writes"].append(["patch", k])
    elif k == "deployment" and name == "tokenfuse-gateway":
        before = json.dumps(st["deployment"]["spec"]["template"], sort_keys=True)
        merge(st["deployment"], body)
        if json.dumps(st["deployment"]["spec"]["template"], sort_keys=True) != before:
            st["writes"].append(["patch", "deployment"])
            roll()
    else:
        die("patch of an unexpected object")
    save()
elif a[:2] == ["rollout", "status"]:
    pass
elif a[:2] == ["get", "pods"] and "json" in a:
    print(json.dumps({"items": st["pods"]}))
elif a[:1] == ["logs"] and len(a) >= 2:
    for p in st["pods"]:
        if p["metadata"]["name"] == a[1]:
            sys.stdout.write(p["log"])
            break
    else:
        die("no such pod", 1)
else:
    die("unknown call")
PY
  chmod +x "$bin/kubectl"
  new_state() { # file: a cluster with the stack installed and nothing given yet
    python3 - "$1" "$IMG" "$GATEWAY_CMD" <<'PY'
import json, sys
dep = {"metadata": {"name": "tokenfuse-gateway"},
       "spec": {"template": {"metadata": {"labels": {"app": "tokenfuse-gateway"}},
                             "spec": {"containers": [{"name": "gateway", "image": sys.argv[2],
                                                      "command": [sys.argv[3]]}]}}}}
json.dump({"deployment": dep, "secret": None, "configmap": None, "rv": 100, "rollouts": 0,
           "writes": [], "pods": [{"metadata": {"name": "gateway-0", "annotations": {},
                                                "creationTimestamp": "2026-10-13T10:00:00Z"},
                                   "status": {"phase": "Running"},
                                   "log": "tokenfuse gateway listening addr=0.0.0.0:4100\n"}]},
          open(sys.argv[1], "w"))
PY
  }
  drun() { # state args...: identity/up.sh against the stub, from the operator's directory
    local s="$1"
    shift
    (cd "$op" && env -i PATH="$bin:$PATH" HOME="$HOME" STUB_STATE="$s" STUB_CALLS="$s.calls" \
      GATE_DOCKER_LOG="$s.docker" SECRET_KEY="$SECRET_KEY" MAP_KEY="$MAP_KEY" STUB_LOGS_LIE="${STUB_LOGS_LIE:-}" \
      NS=agent-stack "$ROOT/$UP" "$@"; printf 'rc=%s\n' "$?") 2>&1
  }
  st_get() { python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));print(eval(sys.argv[2]))' "$1" "$2"; }
  spec_in() { python3 -c 'import base64,json,sys;s=json.load(open(sys.argv[1]));print(base64.b64decode(s["secret"]["data"][sys.argv[2]]).decode())' "$1" "$SECRET_KEY"; }
  map_is() { python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));print(s["configmap"]["data"][sys.argv[3]].encode()==open(sys.argv[2],"rb").read())' "$1" "$2" "$MAP_KEY"; }
  writes() { st_get "$1" 'len(s["writes"])'; }
  rolls() { st_get "$1" 's["rollouts"]'; }
  ann() { st_get "$1" "s['deployment']['spec']['template']['metadata'].get('annotations',{}).get('$2','')"; }

  S="$scratch/d.state"
  new_state "$S"
  out="$(drun "$S" --client-keys-file keys.txt --identity-map-file map.json)"
  if [ "$(rc_of "$out")" != 0 ]; then
    fail "a first run with a valid keys file and map failed: $(grep -v '^rc=' <<<"$out" | tail -n 3 | tr '\n' ' ')"
  else
    [ "$(rolls "$S")" = 1 ] || fail "a first run with both files rolled the gateway $(rolls "$S") time(s), not once"
    [ "$(spec_in "$S")" = "$SPEC2" ] || fail "the Secret does not hold the keys given, as one spec"
    [ "$(map_is "$S" "$op/map.json")" = True ] || fail "the ConfigMap does not hold the map given, byte for byte"
    [ "$(st_get "$S" 's["configmap"]["data"]["'"$MAP_PATH_KEY"'"]')" = "$MAP_DIR/$MAP_KEY" ] \
      || fail "the ConfigMap's path key is not the file inside the mount, $MAP_DIR/$MAP_KEY"
    [ "$(ann "$S" "$ANN_MAP")" = "$(sha_of "$op/map.json")" ] \
      || fail "the gateway's pod template does not carry the sha256 of the map it was given"
    [ "$(ann "$S" "$ANN_KEYS")" = "$(st_get "$S" 's["secret"]["metadata"]["resourceVersion"]')" ] \
      || fail "the gateway's pod template does not carry the version of the Secret it reads"
    if has_secret "$out"; then fail "a run printed a secret"; fi
    if has_secret "$(cat "$S.calls")"; then fail "a secret appeared on a kubectl command line"; fi
    if has_secret "$(cat "$S.docker" 2>/dev/null)"; then fail "a secret appeared on the docker command line"; fi

    w="$(writes "$S")"
    out="$(drun "$S")"
    [ "$(rc_of "$out")" = 0 ] || fail "a re-run that names no file failed, so a later run would stop: $(grep -v '^rc=' <<<"$out" | tail -n 2 | tr '\n' ' ')"
    [ "$(writes "$S")" = "$w" ] || fail "a re-run that names no file wrote to the cluster, so it rotates or rewrites what it was asked to keep"
    [ "$(rolls "$S")" = 1 ] || fail "a re-run that names no file rolled the gateway"

    out="$(drun "$S" --identity-map-file map.json)"
    [ "$(writes "$S")" = "$w" ] && [ "$(rolls "$S")" = 1 ] \
      || fail "the same map given again wrote or rolled the gateway, which restarts it for nothing"

    out="$(drun "$S" --identity-map-file map2.json)"
    [ "$(rolls "$S")" = 2 ] || fail "a new map did not roll the gateway, so it keeps the map it read at start: $(grep -v '^rc=' <<<"$out" | tail -n 2 | tr '\n' ' ')"
    [ "$(ann "$S" "$ANN_MAP")" = "$(sha_of "$op/map2.json")" ] || fail "a new map did not change the sha256 the pod template carries"

    out="$(drun "$S" --client-keys-file keys3.txt)"
    [ "$(rolls "$S")" = 3 ] || fail "a new keys file did not roll the gateway, so it keeps the keys it read at start: $(grep -v '^rc=' <<<"$out" | tail -n 2 | tr '\n' ' ')"
    [ "$(spec_in "$S")" = "$SPEC3" ] || fail "a new keys file did not REPLACE the spec in the Secret"
    if has_secret "$(cat "$S.calls")"; then fail "a secret appeared on a kubectl command line when the Secret was replaced"; fi

    w="$(writes "$S")"
    out="$(drun "$S" --client-keys-file keys-treasury-only.txt)"
    [ "$(rc_of "$out")" != 0 ] || fail "a keys file that drops a key the kept map binds was accepted"
    [ "$(writes "$S")" = "$w" ] && [ "$(rolls "$S")" = 3 ] || fail "a refused keys file still wrote to the cluster"

    out="$(STUB_LOGS_LIE=1 drun "$S" --identity-map-file map.json)"
    [ "$(rc_of "$out")" != 0 ] || fail "a gateway that reported another number of keys than it was given was believed"
  fi
  S2="$scratch/d2.state"
  new_state "$S2"
  out="$(drun "$S2" --identity-map-file map.json)"
  [ "$(rc_of "$out")" != 0 ] || fail "a map with key bindings on a cluster with no client keys was accepted"
  [ "$(writes "$S2")" = 0 ] || fail "a refused map still wrote to the cluster"
  grep -qF 'requires client keys' <<<"$out" || fail "a run that would leave the gateway no keys was not refused for that reason: $(grep -v '^rc=' <<<"$out" | tail -n 1)"

  # A cluster whose keys a deploy minted (lib/identity-mint.sh, invariant 50): the
  # minted map binds the minted key ids, so one file alone is refused, and both
  # together make the keys the operator's, which a later deploy leaves alone.
  S3="$scratch/d3.state"
  new_state "$S3"
  out="$(drun "$S3" --client-keys-file keys.txt --identity-map-file map.json)"
  python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));s["secret"]["metadata"]["labels"]={"taipanbox.dev/identity":"minted"};json.dump(s,open(sys.argv[1],"w"))' "$S3"
  w="$(writes "$S3")"
  out="$(drun "$S3" --client-keys-file keys3.txt)"
  [ "$(rc_of "$out")" != 0 ] && grep -qF 'together' <<<"$out" || fail "a keys file alone on a cluster whose keys a deploy minted was accepted"
  out="$(drun "$S3" --identity-map-file map2.json)"
  [ "$(rc_of "$out")" != 0 ] || fail "a map alone on a cluster whose keys a deploy minted was accepted"
  [ "$(writes "$S3")" = "$w" ] || fail "a refused file on a minted cluster still wrote to it"
  out="$(drun "$S3" --client-keys-file keys3.txt --identity-map-file map.json)"
  [ "$(rc_of "$out")" = 0 ] || fail "both files on a cluster whose keys a deploy minted were refused: $(grep -v '^rc=' <<<"$out" | tail -n 2 | tr '\n' ' ')"
  [ -z "$(st_get "$S3" "(s['secret']['metadata'].get('labels') or {}).get('taipanbox.dev/identity', '')")" ] \
    || fail "the operator's keys kept the minted label, so the next deploy would treat them as its own"
  if has_secret "$(cat "$S3.calls")"; then fail "a secret appeared on a kubectl command line on the minted cluster"; fi
fi

# ---- E. verify.sh asks the running gateway -------------------------------------------------
if want E; then
  # jsonpath escapes the dots of an annotation's name; the names are compared without them.
  sect="$(sed -n '/^head_ "client keys and the identity map"$/,/^head_ /p' verify.sh | grep -v '^[[:space:]]*#' | tr -d '\\')"
  if [ -z "$sect" ]; then
    fail "verify.sh has no 'client keys and the identity map' section, so nothing asks a running gateway"
  else
    if ! grep -qF "$SECRET_NAME" <<<"$sect" || ! grep -qF "'nokey'" <<<"$sect" || ! grep -qF '401' <<<"$sect"; then
      fail "verify.sh no longer asks the running gateway to refuse a call with no key while $SECRET_NAME exists"
    fi
    if ! grep -qF "$ANN_MAP" <<<"$sect" || ! grep -qF "$ANN_KEYS" <<<"$sect" || ! grep -qF "$MAP_CONFIGMAP" <<<"$sect"; then
      fail "verify.sh no longer compares what the gateway's pod template says it read with the Secret and the ConfigMap"
    fi
  fi
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 39."
  exit 1
fi
echo "OK: every gateway start reads the client keys from a required Secret and the identity map from an optional ConfigMap, the map"
echo "    mounted read only; identity/up.sh refuses hostile files before any tool runs, lets the pinned"
echo "    gateway image read the pair with no network before the cluster is written, keeps both on a"
echo "    re-run, rolls the gateway exactly when what it reads changed, never puts a secret on a command"
echo "    line, and believes no gateway that reports other keys; verify.sh asks the running gateway."
