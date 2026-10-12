#!/usr/bin/env bash
# Enforces CLAUDE.md invariant 36: closing a retained reservation is off by
# default, and when closure/up.sh turns it on, the gateway and the console read
# the same secret bytes, which nothing prints.
#
# WHY
#
# tokenfuse D8 lets a person close a retained reservation with evidence. The
# console mints a short-lived token after a passkey assertion and the gateway
# verifies it, both keyed by one shared secret. Turning that on is the
# operator's decision, so it must not arrive with the default apply, and when it
# is on the two sides must hold the same bytes: the console trims whitespace
# from the file it reads, the gateway reads its variable as given, so a
# newline on one side makes every token fail with nothing else wrong.
#
# WHAT THIS CHECKS
#
# 1. manifests/kustomization.yaml's resources: list names no 57-closure file.
# 2. Neither manifests/10-planes.yaml (the gateway) nor manifests/20-console.yaml
#    (the console) carries TOKENFUSE_CLOSURE_SECRET or
#    GENARYX_CLOSURE_SECRET_FILE: those arrive only through closure/up.sh's two
#    `kubectl patch` calls.
# 3. The gateway patch reads TOKENFUSE_CLOSURE_SECRET from the closure-keys
#    Secret, key `secret`; the console patch's GENARYX_CLOSURE_SECRET_FILE names
#    exactly the file its closure-keys volume mounts; each unpatch deletes what
#    its patch adds.
# 4. closure/up.sh creates closure-keys only when it is absent (a re-run reuses
#    it), with --from-literal and never --from-file, from a value with no
#    newline, and expands the secret nowhere but its length check and that
#    create line.
# 5. No script under closure/ applies a Namespace object (GOTCHAS 114).
#
# AND IT REFUSES TO REPORT OK ON NOTHING: a missing patch, unpatch or up.sh, or
# a kustomization with no resources: block, is a failure that says so.
#
# What this does NOT check: that a running gateway accepts a token a running
# console minted, which needs a cluster and images that include D8, the thing
# invariants 4 and 5 already say this repository cannot hold in a gate.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

python3 - <<'PY'
import pathlib
import re
import sys

KUSTOMIZATION = pathlib.Path("manifests/kustomization.yaml")
GATEWAY_PATCH = pathlib.Path("manifests/57-closure-gateway-patch.yaml")
GATEWAY_UNPATCH = pathlib.Path("manifests/57-closure-gateway-unpatch.yaml")
CONSOLE_PATCH = pathlib.Path("manifests/57-closure-console-patch.yaml")
CONSOLE_UNPATCH = pathlib.Path("manifests/57-closure-console-unpatch.yaml")
UP = pathlib.Path("closure/up.sh")
DEFAULT_GATEWAY = pathlib.Path("manifests/10-planes.yaml")
DEFAULT_CONSOLE = pathlib.Path("manifests/20-console.yaml")

for p in (GATEWAY_PATCH, GATEWAY_UNPATCH, CONSOLE_PATCH, CONSOLE_UNPATCH, UP, KUSTOMIZATION):
    if not p.exists():
        print(f"FAIL: {p} does not exist.")
        print("This measured nothing about whether closing is off by default.")
        sys.exit(1)

errors = []

# ---- 1. not in the default apply set ----------------------------------------
ktext = KUSTOMIZATION.read_text()
m = re.search(r"^resources:\s*$", ktext, re.M)
resources = []
if m:
    for line in ktext[m.end():].splitlines():
        if not line.strip():
            continue
        im = re.match(r"^\s*-\s+(\S+)\s*$", line)
        if not im:
            break
        resources.append(im.group(1))
if not resources:
    print(f"FAIL: {KUSTOMIZATION} has no resources: block, so this measured nothing.")
    sys.exit(1)
for r in resources:
    if r.startswith("57-closure"):
        errors.append(f"{r} is listed in {KUSTOMIZATION}'s resources: closing must stay "
                      "opt-in, applied only by closure/up.sh")

# ---- 2. the default manifests carry no closure setting ----------------------
CLOSURE_ENV = re.compile(r"\b(TOKENFUSE_CLOSURE_SECRET|GENARYX_CLOSURE_SECRET_FILE)\b")
for path in (DEFAULT_GATEWAY, DEFAULT_CONSOLE):
    if not path.exists():
        errors.append(f"{path} does not exist, so this measured nothing about its env vars")
        continue
    found = sorted(set(CLOSURE_ENV.findall(path.read_text())))
    if found:
        errors.append(f"{path} carries {found}, a closure setting, in the manifest the "
                      "default apply set installs; it may only arrive through closure/up.sh")

# ---- 3. the patches agree with each other and with their unpatches ----------
gp = GATEWAY_PATCH.read_text()
if not re.search(r"name:\s*TOKENFUSE_CLOSURE_SECRET\s*\n\s*valueFrom:\s*\{\s*secretKeyRef:\s*"
                 r"\{\s*name:\s*closure-keys,\s*key:\s*secret\s*\}\s*\}", gp):
    errors.append(f"{GATEWAY_PATCH} does not read TOKENFUSE_CLOSURE_SECRET from the "
                  "closure-keys Secret, key `secret`")
if not re.search(r"\{\s*name:\s*TOKENFUSE_CLOSURE_SECRET,\s*\$patch:\s*delete\s*\}",
                 GATEWAY_UNPATCH.read_text()):
    errors.append(f"{GATEWAY_UNPATCH} does not delete TOKENFUSE_CLOSURE_SECRET")

cp = CONSOLE_PATCH.read_text()
fm = re.search(r"name:\s*GENARYX_CLOSURE_SECRET_FILE,\s*value:\s*\"([^\"]+)\"", cp)
mm = re.search(r"\{\s*name:\s*([\w-]+),\s*mountPath:\s*(\S+?),\s*readOnly:\s*true\s*\}", cp)
vm = re.search(r"-\s*name:\s*([\w-]+)\s*\n\s*secret:\s*\n\s*secretName:\s*closure-keys\s*\n"
               r"\s*items:\s*\[\{\s*key:\s*secret,\s*path:\s*([\w.-]+)\s*\}\]", cp)
if not (fm and mm and vm):
    errors.append(f"{CONSOLE_PATCH} lacks one of: GENARYX_CLOSURE_SECRET_FILE, a read-only "
                  "volumeMount, a closure-keys secret volume with key `secret`")
else:
    if mm.group(1) != vm.group(1):
        errors.append(f"{CONSOLE_PATCH} mounts volume {mm.group(1)!r} but declares "
                      f"{vm.group(1)!r} for closure-keys")
    want = mm.group(2).rstrip("/") + "/" + vm.group(2)
    if fm.group(1) != want:
        errors.append(f"{CONSOLE_PATCH}'s GENARYX_CLOSURE_SECRET_FILE is {fm.group(1)!r}, which "
                      f"does not name the file the patch mounts ({want!r})")
    cu = CONSOLE_UNPATCH.read_text()
    for what, rx in (
        ("GENARYX_CLOSURE_SECRET_FILE",
         r"\{\s*name:\s*GENARYX_CLOSURE_SECRET_FILE,\s*\$patch:\s*delete\s*\}"),
        (f"the mount at {mm.group(2)}",
         r"\{\s*mountPath:\s*" + re.escape(mm.group(2)) + r",\s*\$patch:\s*delete\s*\}"),
        (f"the volume {vm.group(1)}",
         r"\{\s*name:\s*" + re.escape(vm.group(1)) + r",\s*\$patch:\s*delete\s*\}"),
    ):
        if not re.search(rx, cu):
            errors.append(f"{CONSOLE_UNPATCH} does not delete {what}, so closure/down.sh "
                          "would leave it on the console")

# ---- 4. up.sh mints once, without a newline, and never prints it ------------
lines = UP.read_text().splitlines()
code = [(n, ln) for n, ln in enumerate(lines, 1) if not ln.lstrip().startswith("#")]
creates = [(n, ln) for n, ln in code if "create secret generic closure-keys" in ln]
if not creates:
    errors.append(f"{UP} never creates the closure-keys Secret, so this measured nothing "
                  "about how it is minted")
reuse = [n for n, ln in code if re.search(r"\bif\b.*\bget secret closure-keys\b", ln)]
for n, ln in creates:
    if "--from-file" in ln:
        errors.append(f"{UP}:{n} creates closure-keys with --from-file: a file's trailing "
                      "newline would reach the gateway and not the console")
    if not re.search(r"--from-literal=\"?secret=", ln):
        errors.append(f"{UP}:{n} creates closure-keys without --from-literal=secret=")
    if not reuse or reuse[0] > n:
        errors.append(f"{UP}:{n} creates closure-keys without first checking it exists, so a "
                      "re-run would mint a second secret")
if not any(re.search(r"CLOSURE_SECRET=.*tr -d ' \\n'", ln) for _, ln in code):
    errors.append(f"{UP} does not mint the secret through `tr -d ' \\n'`, so nothing keeps a "
                  "newline out of it")
for n, ln in code:
    if not re.search(r"\$\{?#?CLOSURE_SECRET\b", ln):
        continue
    if "${#CLOSURE_SECRET}" in ln and not re.search(
            r"\$\{?CLOSURE_SECRET\b", ln.replace("${#CLOSURE_SECRET}", "")):
        continue
    if "create secret generic closure-keys" in ln:
        continue
    errors.append(f"{UP}:{n} expands the closure secret outside its length check and the "
                  f"create line, where it could be printed: {ln.strip()!r}")

# ---- 5. no Namespace object from an opt-in script ----------------------------
NS_APPLY = re.compile(r"create\s+namespace\b[^\n]*\|\s*kubectl\s+apply|kind:\s*Namespace")
for path in sorted(pathlib.Path("closure").glob("*.sh")):
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if not line.lstrip().startswith("#") and NS_APPLY.search(line):
            errors.append(f"{path}:{n} applies a Namespace object; an opt-in script must "
                          "require the installed namespace, never re-apply it")

if errors:
    for e in errors:
        print(f"FAIL: {e}")
    print()
    print(f"{len(errors)} way(s) closing is not off by default, or its two halves disagree. "
          "See CLAUDE.md invariant 36.")
    sys.exit(1)

print("OK: the closure patches stay out of the default apply set, neither default manifest "
      "carries a closure setting, the console reads the file its volume mounts, each unpatch "
      "removes what its patch adds, and closure/up.sh mints the secret once, without a "
      "newline, printing it nowhere.")
PY
