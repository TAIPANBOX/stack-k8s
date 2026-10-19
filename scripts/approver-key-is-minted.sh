#!/usr/bin/env bash
# CLAUDE.md invariant 67. An approval names the person who gave it: the console signs an approver statement
# with a P-256 key only it holds, and wardryx verifies it against the public half. This gate holds the key's
# shape, its wiring into the console and wardryx, its minting (once, never rewritten, never on a command line),
# and that nothing turns on the bearer-key override WARDRYX_ALLOW_KEY_APPROVALS.
#
# WHAT THIS CHECKS
#
#   1. lib/approver-mint.sh defines approver_mint_settle, creates its objects with `create -f -` on stdin
#      (never apply, replace or patch), makes the key with openssl on prime256v1 as PKCS#8 (no -nocrypt
#      omitted), and passes the key to secret_doc as a file.
#   2. Each deploy path (deploy.sh, cloud/gcp/deploy-gcp.sh, cloud/aws/deploy-aws.sh) sources it and calls
#      approver_mint_settle AFTER its last `apply -k`.
#   3. manifests/20-console.yaml: GENARYX_APPROVER_KEY_FILE names the file a read-only mount of the Secret
#      console-approver-key provides, at mode 0440, not optional.
#   4. manifests/10-planes.yaml is in one of two states, and this gate names which. v1.6.0: wardryx sets no
#      WARDRYX_APPROVER_JWKS and mounts no JWK set, and TODO(approver-jwks) names the next step. v1.6.1: wardryx sets
#      WARDRYX_APPROVER_JWKS, reads the ConfigMap wardryx-approver-jwks from a read-only mount that is not optional,
#      carries no TODO(approver-jwks), and manifests/20-console.yaml pins genaryx-console:v1.6.0 by digest (the console
#      that sends the statement). A mixed state fails. wardryx runs v2.4.0 or later pinned by digest in both states.
#   5. No live manifest, script or library sets WARDRYX_ALLOW_KEY_APPROVALS.
#   6. Behaviour: approver_mint_settle, run with a stub kubectl, mints a PKCS#8 P-256 key and its JWK set when
#      the cluster holds neither; keeps both without a create when it holds both; and refuses a half pair.
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import re
import sys

bad = []
LIB = "lib/approver-mint.sh"
DEPLOY = ["deploy.sh", "cloud/gcp/deploy-gcp.sh", "cloud/aws/deploy-aws.sh"]
M20 = "manifests/20-console.yaml"
M10 = "manifests/10-planes.yaml"


def read(path):
    try:
        return open(path).read()
    except OSError:
        return None


def live(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


lib = read(LIB)
if lib is None:
    print(f"FAIL {LIB} is absent: the approver key is measured NOTHING")
    sys.exit(1)
lib_live = live(lib)
if "approver_mint_settle()" not in lib:
    bad.append(f"{LIB} defines no approver_mint_settle")
for verb in ("apply", "replace", "patch"):
    if re.search(rf"k_ \"[^\"]*\b{verb}\b", lib_live):
        bad.append(f"{LIB} runs `{verb}` on the approver objects, which would rewrite a key that exists")
if not re.search(r'create -f -', lib_live):
    bad.append(f"{LIB} creates its objects without `create -f -` on stdin")
if "openssl ecparam -name prime256v1" not in lib_live:
    bad.append(f"{LIB} does not make a P-256 key (openssl ecparam -name prime256v1)")
if "pkcs8 -topk8 -nocrypt" not in lib_live:
    bad.append(f"{LIB} does not write the key as unencrypted PKCS#8 (pkcs8 -topk8 -nocrypt)")
if not re.search(r"secret_doc\s+\"?\$APPROVER_SECRET\"?\s+\"approver\.pem=@", lib_live):
    bad.append(f"{LIB} does not pass the key to secret_doc as a file (KEY=@FILE)")

for path in DEPLOY:
    text = read(path)
    if text is None:
        bad.append(f"{path} is absent: its approver-key step is measured NOTHING")
        continue
    t = live(text)
    if not re.search(r'\. "\$ROOT/lib/approver-mint\.sh"', t):
        bad.append(f"{path} does not source lib/approver-mint.sh")
    calls = [m.start() for m in re.finditer(r"^approver_mint_settle\s*$", t, re.M)]
    applies = [m.start() for m in re.finditer(r'k_ "apply -k[^"]*manifests"', t)]
    if not calls:
        bad.append(f"{path} never calls approver_mint_settle")
    elif not applies:
        bad.append(f"{path} has no `apply -k`, so the call cannot be ordered after it")
    elif calls[0] < applies[-1]:
        bad.append(f"{path} calls approver_mint_settle before its last apply -k")

m20 = read(M20)
if m20 is None:
    bad.append(f"{M20} is absent: the console's approver wiring is measured NOTHING")
else:
    t = live(m20)
    env = re.search(r'GENARYX_APPROVER_KEY_FILE, value: "([^"]+)"', t)
    if env is None:
        bad.append(f"{M20} does not set GENARYX_APPROVER_KEY_FILE")
    else:
        mount = re.search(r"\{ name: approver, mountPath: ([^,]+), readOnly: true \}", t)
        if mount is None:
            bad.append(f"{M20} does not mount the approver volume read only")
        elif env.group(1) != mount.group(1).strip() + "/approver.pem":
            bad.append(f"{M20}: GENARYX_APPROVER_KEY_FILE is {env.group(1)} but the approver volume is mounted at {mount.group(1)}")
    vol = re.search(r"- name: approver\n\s+secret: \{ secretName: console-approver-key, defaultMode: 0440 \}", t)
    if vol is None:
        bad.append(f"{M20}: the approver volume is not the Secret console-approver-key at mode 0440")
    if re.search(r"console-approver-key[^\n]*optional: true", t):
        bad.append(f"{M20}: the approver Secret is optional, so the console would start with no way to sign")

STATE = "unknown"
m10 = read(M10)
if m10 is None:
    bad.append(f"{M10} is absent: wardryx's approver wiring is measured NOTHING")
else:
    t = live(m10)
    env = re.search(r'WARDRYX_APPROVER_JWKS, value: "([^"]+)"', t)
    mount = re.search(r"\{ name: approver-jwks, mountPath: ([^,]+), readOnly: true \}", t)
    volume = re.search(r"- name: approver-jwks\n\s+configMap: \{ name: wardryx-approver-jwks \}", t)
    todo = "TODO(approver-jwks)" in m10
    console_v160 = re.search(r"image: ghcr\.io/taipanbox/genaryx-console:v1\.6\.0@sha256:[0-9a-f]{64}",
                             live(read(M20) or "")) is not None
    if env is None and mount is None and volume is None:
        STATE = "v1.6.0"
        if not todo:
            bad.append(f"{M10}: wardryx does not read the JWK set, and names no TODO(approver-jwks) for v1.6.1, so the next step is not written down")
    elif env is not None and mount is not None and volume is not None:
        STATE = "v1.6.1"
        if env.group(1) != mount.group(1).strip() + "/approver-jwks.json":
            bad.append(f"{M10}: WARDRYX_APPROVER_JWKS is {env.group(1)} but the JWK set is mounted at {mount.group(1)}")
        if todo:
            bad.append(f"{M10}: wardryx reads the JWK set, but TODO(approver-jwks) still names it as pending: the TODO is stale")
        if not console_v160:
            bad.append(f"{M10}: wardryx requires a console statement on every approval, and the console in {M20} is not genaryx-console:v1.6.0 by digest, so every approval would be refused")
    else:
        STATE = "half"
        bad.append(f"{M10}: wardryx's approver wiring is half set: WARDRYX_APPROVER_JWKS, its read-only mount and the wardryx-approver-jwks volume must be present together, or absent together")
    pin = re.search(r"image: ghcr\.io/taipanbox/wardryx:v(\d+)\.(\d+)\.(\d+)@sha256:([0-9a-f]{64})", t)
    if pin is None:
        bad.append(f"{M10} does not pin wardryx by digest")
    elif (int(pin.group(1)), int(pin.group(2)), int(pin.group(3))) < (2, 4, 0):
        bad.append(f"{M10}: wardryx is pinned at v{pin.group(1)}.{pin.group(2)}.{pin.group(3)}, before the approver statements (2.4.0)")

override_hits = []
for root in ("manifests", "lib", "cloud", "identity", "hub", "policy", "keyryx", "tunnel", "scripts"):
    import os
    for dp, _, fns in os.walk(root):
        for fn in fns:
            if not (fn.endswith(".yaml") or fn.endswith(".sh") or fn.endswith(".yml")):
                continue
            p = os.path.join(dp, fn)
            if p.endswith("gates-have-teeth.sh") or p.endswith("approver-key-is-minted.sh"):
                continue
            body = read(p) or ""
            if re.search(r"WARDRYX_ALLOW_KEY_APPROVALS", live(body)):
                override_hits.append(p)
for path in ("deploy.sh", "install.sh", "build.sh"):
    body = read(path) or ""
    if re.search(r"WARDRYX_ALLOW_KEY_APPROVALS", live(body)):
        override_hits.append(path)
for p in override_hits:
    bad.append(f"{p} sets WARDRYX_ALLOW_KEY_APPROVALS: a bearer key would decide holds, which invariant 67 forbids")

if bad:
    for b in bad:
        print("FAIL " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 67.")
    sys.exit(1)
if STATE == "v1.6.0":
    print("STATE v1.6.0: the approver key is minted and mounted in the console; wardryx does not read the JWK set yet "
          "(TODO(approver-jwks), v1.6.1), so approvals are not bound to a console key in this state.")
else:
    print(f"STATE {STATE}: wardryx reads the console's JWK set and requires a statement on every grant and denial; "
          "the console pin is genaryx-console:v1.6.0 by digest.")
print("STATIC-OK")
PY
static_rc=$?
if [ "$static_rc" -ne 0 ]; then
  exit 1
fi

# ---- behaviour: the mint against a stub kubectl ----
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
LOG="$tmp/create"
STATE="$tmp/state"
cat > "$tmp/harness.sh" <<'SH'
#!/usr/bin/env bash
# usage: harness.sh MODE   MODE is "fresh" (neither object), "both" (both present), "half" (secret only)
set -uo pipefail
REPO="$1"; MODE="$2"; LOG="$3"
die() { echo "DIE: $*" >&2; exit 1; }
. "$REPO/lib/secret-doc.sh"
. "$REPO/lib/approver-mint.sh"
k_() {
  case "$1" in
    *"get secret/"*)
      case "$MODE" in
        fresh) : ;;
        both) echo "secret/console-approver-key"; echo "configmap/wardryx-approver-jwks" ;;
        half) echo "secret/console-approver-key" ;;
      esac ;;
    *"create -f -"*) cat > "$LOG"; echo "created" ;;
    *) echo "UNEXPECTED kubectl call: $1" >&2; exit 2 ;;
  esac
}
approver_mint_settle
SH
chmod +x "$tmp/harness.sh"

if ! out="$(bash "$tmp/harness.sh" "$PWD" fresh "$LOG" 2>&1)"; then
  printf 'FAIL the mint did not run on an empty cluster: %s\n' "$out"; exit 1
fi
if ! grep -q "BEGIN PRIVATE KEY" "$LOG" 2>/dev/null && ! printf '%s' "$(sed -n 's/^  approver.pem: //p' "$LOG" | base64 -d 2>/dev/null)" | grep -q "BEGIN PRIVATE KEY"; then
  printf 'FAIL the approver key is not a PKCS#8 "BEGIN PRIVATE KEY" document in the create input\n'; exit 1
fi
if sed -n 's/^  approver.pem: //p' "$LOG" | base64 -d 2>/dev/null | grep -q "EC PRIVATE KEY"; then
  printf 'FAIL the approver key is a SEC1 "EC PRIVATE KEY", not PKCS#8\n'; exit 1
fi
if ! printf '%s' "$out" | grep -q "approver key: minted"; then
  printf 'FAIL the mint did not report minting: %s\n' "$out"; exit 1
fi
if printf '%s' "$out" | grep -q "PRIVATE KEY"; then
  printf 'FAIL the mint printed private key material\n'; exit 1
fi
jwks_line="$(grep -o 'approver-jwks.json: .*' "$LOG" | head -1)"
case "$jwks_line" in
  *'"crv":"P-256"'*) ;;
  *) printf 'FAIL the JWK set is not a P-256 key: %s\n' "$jwks_line"; exit 1 ;;
esac
x="$(printf '%s' "$jwks_line" | sed -n 's/.*"x":"\([^"]*\)".*/\1/p')"
y="$(printf '%s' "$jwks_line" | sed -n 's/.*"y":"\([^"]*\)".*/\1/p')"
if [ "${#x}" -ne 43 ] || [ "${#y}" -ne 43 ]; then
  printf 'FAIL the JWK x and y are not 32-byte base64url values (lengths %s, %s)\n' "${#x}" "${#y}"; exit 1
fi

# A cluster that already holds the pair is left alone: no create at all.
rm -f "$LOG"
if ! out2="$(bash "$tmp/harness.sh" "$PWD" both "$LOG" 2>&1)"; then
  printf 'FAIL a cluster with the pair was not kept: %s\n' "$out2"; exit 1
fi
if [ -e "$LOG" ]; then
  printf 'FAIL a cluster with the pair received a create (the key would be rewritten)\n'; exit 1
fi
if ! printf '%s' "$out2" | grep -q "approver key: kept"; then
  printf 'FAIL a kept pair is not reported as kept: %s\n' "$out2"; exit 1
fi

# A half pair is refused, and nothing is created.
rm -f "$LOG"
if out3="$(bash "$tmp/harness.sh" "$PWD" half "$LOG" 2>&1)"; then
  printf 'FAIL a half pair was accepted, so a mismatched key and JWK set could be written\n'; exit 1
fi
if [ -e "$LOG" ]; then
  printf 'FAIL a half pair received a create\n'; exit 1
fi
if ! printf '%s' "$out3" | grep -q "not both in"; then
  printf 'FAIL a half pair is refused without saying why: %s\n' "$out3"; exit 1
fi

echo "OK: the approver key is PKCS#8 P-256 and its JWK set is written with it when the cluster holds neither; a pair is kept without a create; a half pair is refused. Wired into the console (read-only, 0440, not optional); wardryx v2.4.0 pinned by digest, with its JWK set in the state the STATE line names; WARDRYX_ALLOW_KEY_APPROVALS is set nowhere."
