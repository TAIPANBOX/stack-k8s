#!/usr/bin/env bash
# CLAUDE.md invariant 91. A person deciding a held tool call is shown its arguments: wardryx seals them to the
# console's preview key, and only the console opens them. This gate holds the key's minting (once, never
# rewritten, the private key read back by exec and never through a log or a command line), its wiring into
# the console alone, and wardryx's optional read of the public half.
#
# WHAT THIS CHECKS
#
#   1. lib/preview-mint.sh defines preview_mint_settle, creates its objects with `create -f -` on stdin (never
#      apply, replace or patch), reads the key back with `exec ... cat` and never with `logs`, runs its pod with
#      no service account token and a memory-backed /work, passes the key to secret_doc as a file, and restarts
#      wardryx after the first mint.
#   2. Each deploy path (deploy.sh, cloud/gcp/deploy-gcp.sh, cloud/aws/deploy-aws.sh) sources it and calls
#      preview_mint_settle AFTER its last `apply -k`.
#   3. manifests/20-console.yaml: GENARYX_PREVIEW_KEY_FILE names the file a read-only mount of the Secret
#      console-preview-key provides, at mode 0440, not optional; and no other manifest names that Secret.
#   4. manifests/10-planes.yaml: wardryx reads WARDRYX_PREVIEW_RECIPIENT from the ConfigMap
#      wardryx-preview-recipient, key recipient, optional; wardryx is v2.7.0 or later by digest; and the console
#      in manifests/20-console.yaml is pinned by digest at CONSOLE_MIN or later, the first image that makes and
#      reads the key (an older console cannot decide a sealed hold at all).
#   5. Behaviour: preview_mint_settle, run with a stub kubectl, mints when the cluster holds neither object and
#      prints no private key; keeps both without a create; refuses a half pair; does nothing with no console;
#      and refuses, deleting its pod and creating nothing, when the console image prints no recipient.
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

# The first console image that has `genaryx-web preview-key` and reads GENARYX_PREVIEW_KEY_FILE.
CONSOLE_MIN="${CONSOLE_MIN:-1.12.0}"

CONSOLE_MIN="$CONSOLE_MIN" python3 - <<'PY'
import os
import re
import sys

bad = []
LIB = "lib/preview-mint.sh"
DEPLOY = ["deploy.sh", "cloud/gcp/deploy-gcp.sh", "cloud/aws/deploy-aws.sh"]
M20 = "manifests/20-console.yaml"
M10 = "manifests/10-planes.yaml"
CONSOLE_MIN = tuple(int(x) for x in os.environ["CONSOLE_MIN"].split("."))


def read(path):
    try:
        return open(path).read()
    except OSError:
        return None


def live(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


lib = read(LIB)
if lib is None:
    print(f"FAIL {LIB} is absent: the preview key is measured NOTHING")
    sys.exit(1)
lib_live = live(lib)
if "preview_mint_settle()" not in lib:
    bad.append(f"{LIB} defines no preview_mint_settle")
for verb in ("apply", "replace", "patch"):
    if re.search(rf"k_ \"[^\"]*\b{verb}\b", lib_live):
        bad.append(f"{LIB} runs `{verb}`, which would rewrite a key that exists")
if not re.search(r"create -f -", lib_live):
    bad.append(f"{LIB} creates its objects without `create -f -` on stdin")
if re.search(r"k_ \"[^\"]*\blogs\b", lib_live):
    bad.append(f"{LIB} reads its pod's log: the private key would pass through the container log")
if not re.search(r"exec \$PREVIEW_POD -- cat /work/preview\.key", lib_live):
    bad.append(f"{LIB} does not read the key back with exec ... cat /work/preview.key")
if "automountServiceAccountToken: false" not in lib_live:
    bad.append(f"{LIB}: the mint pod carries a service account token")
if not re.search(r"emptyDir: \{ medium: Memory", lib_live):
    bad.append(f"{LIB}: the mint pod's /work is not memory-backed, so the key would touch the node's disk")
if not re.search(r"secret_doc\s+\"?\$PREVIEW_SECRET\"?\s+\"preview\.key=@", lib_live):
    bad.append(f"{LIB} does not pass the key to secret_doc as a file (KEY=@FILE)")
if not re.search(r'k_ "-n \$PREVIEW_NS rollout restart deployment/wardryx"', lib_live):
    bad.append(f"{LIB} does not restart wardryx after the mint, so wardryx keeps sealing nothing until it restarts")

for path in DEPLOY:
    text = read(path)
    if text is None:
        bad.append(f"{path} is absent: its preview-key step is measured NOTHING")
        continue
    t = live(text)
    if not re.search(r'\. "\$ROOT/lib/preview-mint\.sh"', t):
        bad.append(f"{path} does not source lib/preview-mint.sh")
    calls = [m.start() for m in re.finditer(r"^preview_mint_settle\s*$", t, re.M)]
    applies = [m.start() for m in re.finditer(r'k_ "apply -k[^"]*manifests"', t)]
    if not calls:
        bad.append(f"{path} never calls preview_mint_settle")
    elif not applies:
        bad.append(f"{path} has no `apply -k`, so the call cannot be ordered after it")
    elif calls[0] < applies[-1]:
        bad.append(f"{path} calls preview_mint_settle before its last apply -k")

m20 = read(M20)
if m20 is None:
    bad.append(f"{M20} is absent: the console's preview wiring is measured NOTHING")
else:
    t = live(m20)
    env = re.search(r'GENARYX_PREVIEW_KEY_FILE, value: "([^"]+)"', t)
    mount = re.search(r"\{ name: preview, mountPath: ([^,]+), readOnly: true \}", t)
    if env is None:
        bad.append(f"{M20} does not set GENARYX_PREVIEW_KEY_FILE")
    elif mount is None:
        bad.append(f"{M20} does not mount the preview volume read only")
    elif env.group(1) != mount.group(1).strip() + "/preview.key":
        bad.append(f"{M20}: GENARYX_PREVIEW_KEY_FILE is {env.group(1)} but the preview volume is mounted at {mount.group(1)}")
    if re.search(r"- name: preview\n\s+secret: \{ secretName: console-preview-key, defaultMode: 0440 \}", t) is None:
        bad.append(f"{M20}: the preview volume is not the Secret console-preview-key at mode 0440")
    if re.search(r"console-preview-key[^\n]*optional: true", t):
        bad.append(f"{M20}: the preview Secret is optional, so the console would start unable to open a preview")
    cpin = re.search(r"image: ghcr\.io/taipanbox/genaryx-console:v(\d+)\.(\d+)\.(\d+)@sha256:[0-9a-f]{64}", t)
    if cpin is None:
        bad.append(f"{M20} does not pin genaryx-console by digest")
    elif tuple(int(x) for x in cpin.groups()) < CONSOLE_MIN:
        bad.append(f"{M20}: the console is genaryx-console v{'.'.join(cpin.groups())}, older than v{'.'.join(map(str, CONSOLE_MIN))}, which cannot make the preview key or decide a sealed hold")

holders = []
for dp, _, fns in os.walk("manifests"):
    for fn in fns:
        if fn.endswith(".yaml") and re.search(r"secretName: console-preview-key", live(read(os.path.join(dp, fn)) or "")):
            holders.append(os.path.join(dp, fn))
if holders != [M20] and m20 is not None:
    bad.append(f"the Secret console-preview-key is mounted by {', '.join(holders) or 'nothing'}, not by the console alone")

m10 = read(M10)
if m10 is None:
    bad.append(f"{M10} is absent: wardryx's preview wiring is measured NOTHING")
else:
    t = live(m10)
    ref = re.search(r"- name: WARDRYX_PREVIEW_RECIPIENT\n\s+valueFrom: \{ configMapKeyRef: \{ name: wardryx-preview-recipient, key: recipient, optional: true \} \}", t)
    if ref is None:
        bad.append(f"{M10}: wardryx does not read WARDRYX_PREVIEW_RECIPIENT from the optional ConfigMap wardryx-preview-recipient (key recipient)")
    if re.search(r"WARDRYX_PREVIEW_RECIPIENT, value:", t):
        bad.append(f"{M10}: WARDRYX_PREVIEW_RECIPIENT is a literal value, not the minted recipient")
    if "console-preview-key" in t:
        bad.append(f"{M10} names console-preview-key: the private preview key reaches a plane")
    pin = re.search(r"image: ghcr\.io/taipanbox/wardryx:v(\d+)\.(\d+)\.(\d+)@sha256:[0-9a-f]{64}", t)
    if pin is None:
        bad.append(f"{M10} does not pin wardryx by digest")
    elif tuple(int(x) for x in pin.groups()) < (2, 7, 0):
        bad.append(f"{M10}: wardryx is pinned at v{'.'.join(pin.groups())}, before the argument preview (2.7.0)")

if bad:
    for b in bad:
        print("FAIL " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 91.")
    sys.exit(1)
print("STATIC-OK")
PY
static_rc=$?
if [ "$static_rc" -ne 0 ]; then
  exit 1
fi

# ---- behaviour: the mint against a stub kubectl ----
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/harness.sh" <<'SH'
#!/usr/bin/env bash
# usage: harness.sh REPO MODE DIR   MODE: fresh, both, half, noconsole, oldconsole, badrecipient
set -uo pipefail
REPO="$1"; MODE="$2"; DIR="$3"
die() { echo "DIE: $*" >&2; exit 1; }
export PREVIEW_MINT_POLL=0
. "$REPO/lib/secret-doc.sh"
. "$REPO/lib/preview-mint.sh"
k_() {
  echo "$1" >>"$DIR/calls"
  case "$1" in
    *"get secret/"*)
      case "$MODE" in
        both) echo "secret/console-preview-key"; echo "configmap/wardryx-preview-recipient" ;;
        half) echo "configmap/wardryx-preview-recipient" ;;
      esac ;;
    *"get deployment/genaryx-console"*)
      [ "$MODE" = noconsole ] || echo "ghcr.io/taipanbox/genaryx-console:v9.9.9@sha256:0000" ;;
    *"create -f -"*)
      body="$(cat)"
      if grep -q '^kind: Pod' <<<"$body"; then printf '%s\n' "$body" >"$DIR/pod"; else printf '%s\n' "$body" >"$DIR/objects"; fi ;;
    *"wait --for=condition=Ready"*) : ;;
    *"exec console-preview-mint -- cat /work/recipient"*)
      [ "$MODE" = oldconsole ] && return 1
      if [ "$MODE" = badrecipient ]; then printf '%s\n' "hpke:647a:STUB' x: y"; return 0; fi
      echo "hpke:647a:STUBRECIPIENT" ;;
    *"exec console-preview-mint -- cat /work/preview.key"*) echo "hpke-private:647a:STUBPRIVATEKEYMATERIAL" ;;
    *"delete pod/console-preview-mint"*) echo deleted >>"$DIR/deleted" ;;
    *"rollout restart deployment/wardryx"*) echo restarted >"$DIR/restarted" ;;
    *) echo "UNEXPECTED kubectl call: $1" >&2; return 2 ;;
  esac
}
preview_mint_settle
SH
chmod +x "$tmp/harness.sh"
run() { rm -rf "$tmp/$1"; mkdir -p "$tmp/$1"; bash "$tmp/harness.sh" "$PWD" "$1" "$tmp/$1" 2>&1; }

if ! out="$(run fresh)"; then
  printf 'FAIL the mint did not run on an empty cluster: %s\n' "$out"; exit 1
fi
priv="$(sed -n 's/^  preview.key: //p' "$tmp/fresh/objects" 2>/dev/null | base64 -d 2>/dev/null)"
[ "$priv" = "hpke-private:647a:STUBPRIVATEKEYMATERIAL" ] || { printf 'FAIL the Secret does not carry the key the pod made\n'; exit 1; }
grep -q '^  recipient: hpke:647a:STUBRECIPIENT$' "$tmp/fresh/objects" || { printf 'FAIL the ConfigMap does not carry the recipient the pod printed\n'; exit 1; }
grep -q 'STUBPRIVATEKEYMATERIAL' <<<"$out" && { printf 'FAIL the mint printed the private preview key\n'; exit 1; }
grep -q 'STUBPRIVATEKEYMATERIAL' "$tmp/fresh/calls" && { printf 'FAIL the private preview key reached a kubectl command line\n'; exit 1; }
[ -s "$tmp/fresh/restarted" ] || { printf 'FAIL wardryx was not restarted after the first mint, so it seals nothing until it restarts\n'; exit 1; }
[ -s "$tmp/fresh/deleted" ] || { printf 'FAIL the mint pod was not deleted\n'; exit 1; }
grep -q 'preview key: minted' <<<"$out" || { printf 'FAIL the mint did not report minting: %s\n' "$out"; exit 1; }

out2="$(run both)" || { printf 'FAIL a cluster with the pair was not kept: %s\n' "$out2"; exit 1; }
[ -e "$tmp/both/objects" ] || [ -e "$tmp/both/pod" ] && { printf 'FAIL a cluster with the pair received a create (the key would be rewritten)\n'; exit 1; }
grep -q 'preview key: kept' <<<"$out2" || { printf 'FAIL a kept pair is not reported as kept: %s\n' "$out2"; exit 1; }

if out3="$(run half)"; then
  printf 'FAIL a half pair was accepted, so a recipient the key does not match could stand\n'; exit 1
fi
[ -e "$tmp/half/objects" ] && { printf 'FAIL a half pair received a create\n'; exit 1; }
grep -q 'not both in' <<<"$out3" || { printf 'FAIL a half pair is refused without saying why: %s\n' "$out3"; exit 1; }

out4="$(run noconsole)" || { printf 'FAIL a cluster with no console stopped the deploy: %s\n' "$out4"; exit 1; }
[ -e "$tmp/noconsole/objects" ] && { printf 'FAIL a cluster with no console got a preview key\n'; exit 1; }
grep -q 'preview key: none' <<<"$out4" || { printf 'FAIL no console is not reported: %s\n' "$out4"; exit 1; }

if out5="$(run oldconsole)"; then
  printf 'FAIL a console that printed no recipient was accepted\n'; exit 1
fi
[ -e "$tmp/oldconsole/objects" ] && { printf 'FAIL a console that printed no recipient got a Secret or a ConfigMap\n'; exit 1; }
[ -s "$tmp/oldconsole/deleted" ] || { printf 'FAIL the mint pod was left behind after a refusal\n'; exit 1; }
grep -q 'no X-Wing recipient' <<<"$out5" || { printf 'FAIL the refusal on an old console does not say why: %s\n' "$out5"; exit 1; }

if out6="$(run badrecipient)"; then
  printf 'FAIL a recipient outside base64url was accepted: it would be written into the ConfigMap document\n'; exit 1
fi
[ -e "$tmp/badrecipient/objects" ] && { printf 'FAIL a recipient outside base64url reached a create\n'; exit 1; }

echo "OK: the preview key is minted once by a pod on the console image and read back by exec, never by a log or a command line; a pair is kept, a half pair refused, no console leaves it off, an old console is refused with its pod deleted; the Secret is mounted into the console alone (read-only, 0440, not optional); wardryx v2.7.0 or later reads the recipient from an optional ConfigMap and is restarted once after the mint."
