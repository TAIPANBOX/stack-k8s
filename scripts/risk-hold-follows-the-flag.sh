#!/usr/bin/env bash
# CLAUDE.md invariant 65. With --typed-risk-signal, the policy plane holds a brokered tool call that
# arrives with no risk signal, for a person, and never denies on a signal. Without the flag, no hold
# rule exists and nothing about the policy plane changes.
#
# WHY
#
# A signal can add a hold and nothing else (wardryx v1.2.0, rule hold_if_signal). A missing signal
# is the gap: a padded call, a producer that is down or late, and a call the proxy refuses to ask
# about all arrive with no signal, and without `when_absent: hold` they go on as if harmless
# (wardryx v1.4.0 README, "A missing signal"). The rule is written here, by the same flag that
# turns the proxy on, so the two cannot be set apart by a launcher that forgets one of them.
#
# WHAT THIS CHECKS
#
#   1. manifests/10-planes.yaml: wardryx reads its policy from a DIRECTORY (-policy
#      /etc/wardryx/policy), whose volume projects the starter ConfigMap and, optionally, the
#      ConfigMap wardryx-typed-hold. wardryx loads the file set once at start, so the optional source
#      is what lets the hold exist only when the flag made it.
#   2. `typed/mode.sh hold --typed-risk-signal` renders that ConfigMap with exactly one rule: target
#      agent://*, hold_if_signal on action.risk_class, values drawn from the classes that hold
#      (destructive, external_send, financial; read_only and reversible_change are answers, not holds),
#      min_probability 0.8, when_absent hold, and no key that could deny.
#   3. `typed/mode.sh hold` WITHOUT the flag prints nothing, so no hold object exists unless asked.
#   4. Each of the three launchers (deploy.sh, cloud/gcp/deploy-gcp.sh, cloud/aws/deploy-aws.sh)
#      applies that ConfigMap after the render, only when the flag is on, then restarts the policy
#      plane, because a policy file is read at start and a changed ConfigMap alone changes nothing in
#      a running pod. Each one also clears the ConfigMap and restarts the plane when the flag is off,
#      so a run without the flag removes a hold an earlier run with the flag left behind.
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import os
import re
import subprocess
import sys

bad = []
notes = []

M10 = "manifests/10-planes.yaml"
TYPED = "typed/mode.sh"
LAUNCHERS = ["deploy.sh", "cloud/gcp/deploy-gcp.sh", "cloud/aws/deploy-aws.sh"]
CM = "wardryx-typed-hold"
HOLD_CLASSES = {"destructive", "external_send", "financial"}
ALL_CLASSES = {"read_only", "reversible_change"} | HOLD_CLASSES


def read(path):
    try:
        return open(path).read()
    except OSError:
        return None


def run_typed(args, flag_off=False):
    """typed/mode.sh with the given flags, stdout and stderr, and the exit code."""
    p = subprocess.run(["bash", TYPED] + args, capture_output=True, text=True)
    return p.stdout, p.stderr, p.returncode


# ---- 1. the policy plane reads a directory that holds the optional hold ----
m10 = read(M10)
if m10 is None:
    bad.append(f"{M10} is absent: the policy plane is measured NOTHING")
else:
    doc = None
    for d in re.split(r"\n---\s*\n", m10):
        live = "\n".join(l for l in d.split("\n") if not l.lstrip().startswith("#"))
        if re.search(r"^kind:\s*Deployment\s*$", live, re.M) and re.search(r"^  name:\s*wardryx\s*$", live, re.M):
            doc = live
            break
    if doc is None:
        bad.append(f"{M10}: no wardryx Deployment, so the policy plane is measured NOTHING")
    else:
        if not re.search(r'"-policy",\s*\n?\s*"?/etc/wardryx/policy"?', doc) and not re.search(r'-\s*"/etc/wardryx/policy"', doc):
            bad.append(f"{M10}: wardryx does not read its policy from the directory /etc/wardryx/policy")
        m = re.search(r"- \{ name: policy, mountPath: /etc/wardryx/policy, readOnly: true \}", doc)
        if m is None:
            bad.append(f"{M10}: the policy volume is not mounted at /etc/wardryx/policy read only")
        vol = re.search(r"- name: policy\n(?:[ \t]+.*\n?)+", doc)
        vtext = vol.group(0) if vol else ""
        if "projected:" not in vtext or f"name: {CM}" not in vtext:
            bad.append(f"{M10}: the policy volume does not project the ConfigMap {CM}")
        if not re.search(rf"name: {CM}\s*\n\s*optional: true|name: {CM}, optional: true|optional: true[^\n]*\n?[^\n]*{CM}", vtext) and not re.search(rf"configMap: \{{ name: {CM}, optional: true \}}", vtext):
            if "optional: true" not in vtext:
                bad.append(f"{M10}: the projected {CM} is not optional, so the plane cannot start without a hold")
        if "name: wardryx-policy" not in vtext:
            bad.append(f"{M10}: the policy volume no longer projects the starter ConfigMap wardryx-policy")

# ---- 2 and 3. the hold document, with the flag and without it ----
if read(TYPED) is None:
    bad.append(f"{TYPED} is absent: the hold is measured NOTHING")
else:
    verbs = read(TYPED)
    if not re.search(r"^\s*hold\)\s", verbs, re.M):
        bad.append(f"{TYPED} has no `hold` verb, so the launchers cannot apply the rule")
    out, err, rc = run_typed(["hold", "--with-typed", "--typed-risk-signal"])
    if rc != 0:
        bad.append(f"{TYPED} hold --with-typed --typed-risk-signal exited {rc}: {err.strip()[:200]}")
    else:
        if f"name: {CM}" not in out:
            bad.append(f"{TYPED} hold with the flag renders no ConfigMap {CM}")
        rules = re.findall(r"^\s*- name: (\S+)\s*$", out, re.M)
        if len(rules) != 1:
            bad.append(f"{TYPED} hold with the flag renders {len(rules)} rule(s), expected exactly one")
        if not re.search(r'target:\s*"?agent://\*"?\s*$', out, re.M):
            bad.append(f"{TYPED} hold does not scope the rule to target agent://*")
        if not re.search(r"name:\s*action\.risk_class\s*$", out, re.M):
            bad.append(f"{TYPED} hold does not read the signal action.risk_class")
        vals = re.search(r"values:\s*\[([^\]]*)\]", out)
        if not vals:
            bad.append(f"{TYPED} hold names no values list")
        else:
            got = {v.strip().strip('"\'') for v in vals.group(1).split(",") if v.strip()}
            if not got:
                bad.append(f"{TYPED} hold has an empty values list")
            if got - HOLD_CLASSES:
                bad.append(f"{TYPED} hold holds on {sorted(got - HOLD_CLASSES)}, which is not a hold class (only {sorted(HOLD_CLASSES)})")
            if not got <= ALL_CLASSES:
                bad.append(f"{TYPED} hold names classes typryx does not emit: {sorted(got - ALL_CLASSES)}")
        if not re.search(r"min_probability:\s*0\.8\s*$", out, re.M):
            bad.append(f"{TYPED} hold does not set min_probability 0.8")
        if not re.search(r"when_absent:\s*hold\s*$", out, re.M):
            bad.append(f"{TYPED} hold does not set when_absent: hold, so a missing signal is not held")
        if re.search(r"deny|decision|on_match", out):
            bad.append(f"{TYPED} hold renders a key that could deny (deny, decision or on_match)")
    out0, err0, rc0 = run_typed(["hold", "--with-typed"])
    if rc0 != 0:
        bad.append(f"{TYPED} hold without the flag exited {rc0}: {err0.strip()[:200]}")
    elif out0.strip():
        bad.append(f"{TYPED} hold WITHOUT the flag prints a document, so a hold exists the flag did not ask for")

# ---- 4. each launcher applies the rule after the render, only with the flag, restarts the plane, and clears it without ----
for path in LAUNCHERS:
    text = read(path)
    if text is None:
        bad.append(f"{path} is absent: its risk-hold step is measured NOTHING")
        continue
    live = "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))
    apply_hold = re.search(r'typed/mode\.sh" hold\s[^\n]*\|\s*k_ "apply -f -"', live)
    render_at = re.search(r'typed/mode\.sh" render[^\n]*\|\s*k_ "apply -f -"', live)
    if apply_hold is None:
        bad.append(f"{path}: does not apply the hold ConfigMap through `typed/mode.sh hold | k_ \"apply -f -\"`")
    elif render_at is None or apply_hold.start() < render_at.start():
        bad.append(f"{path}: applies the hold before the typed render, or without one to order against")
    if not re.search(r'TYPED_RISK_SIGNAL" = 1', live):
        bad.append(f"{path}: has no TYPED_RISK_SIGNAL guard for the hold")
    restart = r"rollout restart deployment(/| )wardryx"
    # Each restart must sit inside its own block: the one after the hold's apply, before that block's
    # closing fi, and the one after the clear, before its closing fi. A restart in one block cannot
    # satisfy the other.
    if apply_hold is not None:
        end_of_block = re.search(r"^\s*fi\s*$", live[apply_hold.end():], re.M)
        span = live[apply_hold.end(): apply_hold.end() + (end_of_block.start() if end_of_block else 0)]
        if not re.search(restart, span):
            bad.append(f"{path}: does not restart wardryx after the hold changes, so the running pod keeps the old policy")
    clear = re.search(rf"delete configmap {CM}\b[^\n]*--ignore-not-found", live)
    if clear is None:
        bad.append(f"{path}: does not clear {CM} when the flag is off, so a hold from an earlier run stays")
    else:
        end_of_block = re.search(r"^\s*fi\s*$", live[clear.end():], re.M)
        span = live[clear.end(): clear.end() + (end_of_block.start() if end_of_block else 0)]
        if not re.search(restart, span):
            bad.append(f"{path}: clears {CM} without restarting wardryx, so the running pod keeps the removed rule")

if bad:
    for b in bad:
        print("FAIL " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 65.")
    sys.exit(1)

print("OK: with --typed-risk-signal the policy plane holds a brokered call that arrives with no "
      "action.risk_class signal, and holds nothing else; without the flag no hold exists, and each "
      "launcher applies, restarts and clears it.")
PY
