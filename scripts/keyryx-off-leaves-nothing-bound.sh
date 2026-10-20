#!/usr/bin/env bash
# Enforces CLAUDE.md invariant 76: turning Keyryx off, by keyryx/down.sh or by a deploy with
# --without-keyryx (both run keyryx_remove_settle), leaves no record-seal Job bound to the witness,
# and a read of the cluster that fails stops the run instead of reading as "not there".
#
# WHY
#
# keyryx/record-seal-patch.yaml puts a required pod affinity to app: keyryx-witness on the
# record-seal CronJob's pod template, and record-seal-unpatch.yaml takes it off again. A Job the
# CronJob made before the unpatch keeps the template it was made from. Once keyryx/down.sh deletes
# the witness, a pod of that Job can never be scheduled, and the CronJob's concurrencyPolicy Forbid
# then holds back every later seal: the record stops being sealed and nothing says so.
#
# A read written as `[ -n "$(kubectl get ...)" ]` swallows the read's own failure: the empty
# output reads as "not installed", so down.sh skipped the rollout wait and keyryx_patch_reader
# skipped the patch, both with exit 0.
#
# WHAT THIS CHECKS, by running the real keyryx/down.sh, and lib/keyryx-install.sh's own functions,
# against a stand-in kubectl that keeps the cluster in a file and logs every call:
#
#   down.sh   a record-seal Job bound to the witness that has not started   deleted, with its pods,
#                                                                           before the witness is
#   down.sh   a bound seal that is running                                  let finish, not deleted
#   down.sh   a bound seal still running when the wait ends                 deleted
#   down.sh   a finished bound seal, an unbound seal, another CronJob's Job left alone
#   down.sh   a bound seal still there after the delete                     stops, nothing deleted
#   down.sh   the Jobs cannot be read                                       stops, nothing deleted
#   down.sh   a Deployment it waits on cannot be read                       stops, nothing deleted
#   down.sh   its output does not say that custody or the witness stays
#   opt-out   keyryx_remove_settle releases a bound seal after the record-seal unpatch
#   reader    keyryx_patch_reader on a Deployment it cannot read            stops, nothing patched
#   reader    keyryx_patch_reader on a Deployment that is not there         skipped, exit 0
#   reader    keyryx_patch_reader on a Deployment that is there             patched and rolled out
#
# A subject that is absent, or a case whose planted failure was never reached, is "measured
# NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

GATE_ROOT="$(pwd)" TMP_DIR="$tmp" python3 - <<'PY'
import json
import os
import re
import subprocess
import sys

ROOT = os.environ["GATE_ROOT"]
TMP = os.environ["TMP_DIR"]
bad = []

for subject in ("keyryx/down.sh", "lib/keyryx-install.sh", "keyryx/heraldyx-findings-patch.yaml"):
    if not os.path.exists(os.path.join(ROOT, subject)):
        print(f"keyryx-off: {subject} is absent, so this gate measured NOTHING")
        sys.exit(1)

# The stand-in kubectl. STUB_STATE holds the cluster, STUB_LOG gets one line per call.
STUB = r'''#!/usr/bin/env python3
import json, os, sys
state_path, log_path = os.environ["STUB_STATE"], os.environ["STUB_LOG"]
st = json.load(open(state_path))
args = sys.argv[1:]
if len(args) >= 2 and args[0] == "-n":
    args = args[2:]
line = " ".join(args)
open(log_path, "a").write(line + "\n")
stdin = "" if sys.stdin.isatty() else sys.stdin.read()

def save():
    json.dump(st, open(state_path, "w"))

for key, nth in st.get("fail", []):
    if key in line:
        c = st.setdefault("counts", {})
        c[key] = c.get(key, 0) + 1
        save()
        if c[key] == nth:
            st.setdefault("reached", []).append(key)
            save()
            sys.stderr.write('error: Get "https://10.0.0.1:6443/apis": dial tcp 10.0.0.1:6443: i/o timeout\n')
            sys.exit(1)

BOUND_SPEC = {
    "affinity": {"podAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": [
        {"labelSelector": {"matchLabels": {"app": "keyryx-witness"}}, "topologyKey": "kubernetes.io/hostname"}]}},
    "containers": [{"name": "trailryx", "env": [{"name": "TRAILRYX_SIGNER", "value": "keyryx"}]}],
}
FREE_SPEC = {"containers": [{"name": "trailryx", "env": []}]}

def listing():
    items = []
    for j in st["jobs"]:
        spec = BOUND_SPEC if j["bound"] else FREE_SPEC
        if j.get("finish_after") is not None and st.get("reads", 0) >= j["finish_after"]:
            j["done"] = True
            for p in j["pods"]:
                p["phase"] = "Succeeded"
        status = {"conditions": [{"type": "Complete", "status": "True"}]} if j.get("done") else {"active": 1}
        items.append({"kind": "Job", "metadata": {"name": j["name"], "ownerReferences": [{"kind": "CronJob", "name": j.get("owner", "record-seal")}]},
                      "spec": {"template": {"spec": spec}}, "status": status})
        for p in j["pods"]:
            items.append({"kind": "Pod", "metadata": {"name": p["name"], "ownerReferences": [{"kind": "Job", "name": j["name"]}]},
                          "spec": spec, "status": {"phase": p["phase"]}})
    return {"apiVersion": "v1", "kind": "List", "items": items}

if args[:1] == ["get"] and len(args) >= 3 and args[1] in ("deployment", "cronjob"):
    group = {"deployment": "deployment.apps", "cronjob": "cronjob.batch"}[args[1]]
    if args[2] in st.get(args[1] + "s", []):
        print(f"{group}/{args[2]}")
    elif "--ignore-not-found" not in args:
        sys.stderr.write(f'Error from server (NotFound): {group.split(".")[0]}s.{group.split(".")[1]} "{args[2]}" not found\n')
        sys.exit(1)
    sys.exit(0)
if args[:2] == ["get", "jobs,pods"]:
    if st.get("fail_listing"):
        sys.stderr.write("error: the server is currently unable to handle the request (get jobs.batch)\n")
        sys.exit(1)
    st["reads"] = st.get("reads", 0) + 1
    out = listing()
    save()
    print(json.dumps(out))
    sys.exit(0)
if args[:1] == ["patch"] or args[:1] == ["rollout"]:
    sys.exit(0)
if args[:2] == ["delete", "job"]:
    name = args[2]
    st["jobs"] = [j for j in st["jobs"] if j["name"] != name]
    if st.get("respawn"):
        st["jobs"].append({"name": name + "-again", "bound": True, "pods": [{"name": name + "-again-p", "phase": "Pending"}]})
    save()
    sys.exit(0)
if args[:1] == ["delete"]:
    sys.exit(0)
sys.stderr.write("UNEXPECTED kubectl call: " + line + "\n")
sys.exit(9)
'''

stubdir = os.path.join(TMP, "bin")
os.makedirs(stubdir)
with open(os.path.join(stubdir, "kubectl"), "w") as f:
    f.write(STUB)
os.chmod(os.path.join(stubdir, "kubectl"), 0o755)

DEPS = ["wardryx", "genaryx-console", "heraldyx"]


def job(name, bound=True, phase="Pending", done=False, finish_after=None, owner="record-seal"):
    pods = [] if phase is None else [{"name": name + "-p", "phase": phase}]
    return {"name": name, "bound": bound, "pods": pods, "done": done, "finish_after": finish_after, "owner": owner}


def run(n, state, cmd, wait="0"):
    d = os.path.join(TMP, f"case{n}")
    os.makedirs(d)
    sp, lp = os.path.join(d, "state.json"), os.path.join(d, "log")
    state = dict({"deployments": DEPS, "cronjobs": ["record-seal"], "jobs": []}, **state)
    json.dump(state, open(sp, "w"))
    open(lp, "w").close()
    env = {"PATH": stubdir + os.pathsep + os.environ["PATH"], "HOME": os.environ.get("HOME", TMP), "NS": "agent-stack",
           "GATE_ROOT": ROOT, "STUB_STATE": sp, "STUB_LOG": lp, "KEYRYX_SEAL_WAIT": wait, "KEYRYX_SEAL_POLL": "0"}
    p = subprocess.run(["bash", "-c", cmd], env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120, cwd=ROOT)
    log = open(lp).read().split("\n")
    return p.returncode, p.stdout + p.stderr, log, json.load(open(sp))


def at(log, needle):
    for i, l in enumerate(log):
        if needle in l:
            return i
    return -1


DOWN = 'bash "$GATE_ROOT/keyryx/down.sh"'
LIB = 'set -u; ROOT="$GATE_ROOT"; KEYRYX_NS=agent-stack; die() { echo "refused: $*" >&2; exit 3; }; k_() { eval "kubectl $*"; }; . "$GATE_ROOT/lib/keyryx-install.sh"; '
WITNESS_DELETE = "delete deployment keyryx-custody keyryx-witness"
STAYS = re.compile(r"(?i)\b(custody|witness)\b[^.\n]*\bstays?\b")


def ran_nothing(name, log):
    if not any(l.strip() for l in log):
        bad.append(f"{name}: no kubectl call was made, so the case measured NOTHING")
        return True
    return False


def reached(name, st, key):
    if key not in st.get("reached", []):
        bad.append(f"{name}: the planted failure of '{key}' was never reached, so the case measured NOTHING")
        return False
    return True


# 1. down.sh deletes a bound seal that has not started, before the witness, and says nothing stays.
name = "down.sh: a seal bound to the witness that has not started"
rc, out, log, st = run(1, {"jobs": [job("record-seal-1")]}, DOWN)
if not ran_nothing(name, log):
    d, w = at(log, "delete job record-seal-1"), at(log, WITNESS_DELETE)
    if rc != 0:
        bad.append(f"{name}: down.sh exited {rc}: {out.strip()[-300:]}")
    if d < 0:
        bad.append(f"{name}: the Job is not deleted, so its pod stays Pending once the witness is gone and Forbid holds back every later seal")
    elif w >= 0 and d > w:
        bad.append(f"{name}: the Job is deleted after the witness")
    elif "--cascade=foreground" not in log[d] or "--wait=true" not in log[d]:
        bad.append(f"{name}: the Job is deleted without waiting for its pods (--cascade=foreground --wait=true)")
    if at(log, "patch cronjob record-seal") < 0 or (d >= 0 and at(log, "patch cronjob record-seal") > d):
        bad.append(f"{name}: the Job is deleted before the record-seal CronJob is unpatched, so the CronJob can make another bound one")
    if STAYS.search(out):
        bad.append(f"{name}: down.sh says custody or the witness stays, and then deletes them: {STAYS.search(out).group(0)!r}")
    if "Keyryx is off." not in out:
        bad.append(f"{name}: down.sh did not reach its last line")

# 2. a running bound seal is let finish.
name = "down.sh: a running seal bound to the witness"
rc, out, log, st = run(2, {"jobs": [job("record-seal-2", phase="Running", finish_after=3)]}, DOWN, wait="60")
if not ran_nothing(name, log):
    if rc != 0:
        bad.append(f"{name}: down.sh exited {rc}: {out.strip()[-300:]}")
    if at(log, "delete job") >= 0:
        bad.append(f"{name}: a seal that was running is deleted instead of let finish")
    if st.get("reads", 0) < 3:
        bad.append(f"{name}: down.sh read the Jobs {st.get('reads', 0)} time(s), so it did not wait for the running seal")

# 3. a running bound seal that outlasts the wait is deleted.
name = "down.sh: a running seal that outlasts the wait"
rc, out, log, st = run(3, {"jobs": [job("record-seal-3", phase="Running")]}, DOWN, wait="0")
if not ran_nothing(name, log):
    if rc != 0:
        bad.append(f"{name}: down.sh exited {rc}: {out.strip()[-300:]}")
    if at(log, "delete job record-seal-3") < 0:
        bad.append(f"{name}: the Job is still there when the wait ends")

# 4. what is not bound, or is done, or is not the record-seal's, is left alone.
name = "down.sh: a finished seal, an unbound seal and another CronJob's Job"
rc, out, log, st = run(4, {"jobs": [job("record-seal-4", phase="Succeeded", done=True),
                                     job("record-seal-5", bound=False),
                                     job("crypto-trend-1", bound=False, owner="crypto-trend")]}, DOWN)
if not ran_nothing(name, log):
    if rc != 0:
        bad.append(f"{name}: down.sh exited {rc}: {out.strip()[-300:]}")
    if at(log, "delete job") >= 0:
        bad.append(f"{name}: a Job that is not bound to the witness, or is finished, is deleted: {log[at(log, 'delete job')]}")

# 5. a bound seal still there after the delete stops down.sh before it deletes anything of Keyryx.
name = "down.sh: a seal still bound after the delete"
rc, out, log, st = run(5, {"jobs": [job("record-seal-6")], "respawn": True}, DOWN)
if not ran_nothing(name, log):
    if rc == 0:
        bad.append(f"{name}: down.sh exited 0 with a record-seal Job still bound to the witness, so nothing checks what the delete left")
    elif "still bound to the Keyryx witness" not in out:
        bad.append(f"{name}: down.sh stopped without saying a seal is still bound: {out.strip()[-200:]}")
    if at(log, WITNESS_DELETE) >= 0:
        bad.append(f"{name}: down.sh deleted the witness with a seal still bound to it")

# 6. Jobs that cannot be read stop down.sh.
name = "down.sh: the Jobs cannot be read"
rc, out, log, st = run(6, {"jobs": [job("record-seal-7")], "fail_listing": True}, DOWN)
if not ran_nothing(name, log):
    if at(log, "get jobs,pods") < 0:
        bad.append(f"{name}: down.sh never reads the record-seal Jobs")
    if rc == 0:
        bad.append(f"{name}: down.sh exited 0 although it could not read the Jobs")
    if at(log, WITNESS_DELETE) >= 0:
        bad.append(f"{name}: down.sh deleted the witness without knowing whether a seal is bound to it")

# 7. a Deployment down.sh waits on cannot be read: the second read of the console is down.sh's own.
name = "down.sh: a Deployment it waits on cannot be read"
key = "get deployment genaryx-console"
rc, out, log, st = run(7, {"fail": [[key, 2]]}, DOWN)
if not ran_nothing(name, log) and reached(name, st, key):
    if rc == 0:
        bad.append(f"{name}: down.sh exited 0 although it could not read deployment genaryx-console, and skipped its rollout wait")
    elif "could not read deployment genaryx-console" not in out:
        bad.append(f"{name}: down.sh stopped without naming the read that failed: {out.strip()[-200:]}")
    if at(log, WITNESS_DELETE) >= 0:
        bad.append(f"{name}: down.sh deleted the witness after a read it could not make")

# 8. the opt-out (deploy --without-keyryx) releases a bound seal, after the record-seal unpatch.
name = "opt-out: keyryx_remove_settle with a seal bound to the witness"
rc, out, log, st = run(8, {"jobs": [job("record-seal-8")]}, LIB + "keyryx_remove_settle")
if not ran_nothing(name, log):
    d, u = at(log, "delete job record-seal-8"), at(log, "patch cronjob record-seal")
    if rc != 0:
        bad.append(f"{name}: exited {rc}: {out.strip()[-300:]}")
    if d < 0:
        bad.append(f"{name}: the opt-out leaves the Job bound to the witness")
    elif u < 0 or u > d:
        bad.append(f"{name}: the Job is released before the record-seal CronJob is unpatched")

# 9. to 11. keyryx_patch_reader.
name = "reader: keyryx_patch_reader on a Deployment it cannot read"
key = "get deployment heraldyx"
rc, out, log, st = run(9, {"fail": [[key, 1]]}, LIB + "keyryx_patch_reader heraldyx heraldyx-findings-patch.yaml")
if not ran_nothing(name, log) and reached(name, st, key):
    if rc == 0:
        bad.append(f"{name}: exited 0, reading a failed read as 'not installed': {out.strip()[-200:]}")
    elif "could not read deployment heraldyx" not in out:
        bad.append(f"{name}: stopped without naming the read that failed: {out.strip()[-200:]}")
    if at(log, "patch deployment heraldyx") >= 0:
        bad.append(f"{name}: patched a Deployment it could not read")
name = "reader: keyryx_patch_reader on a Deployment that is not there"
rc, out, log, st = run(10, {"deployments": ["wardryx", "genaryx-console"]}, LIB + "keyryx_patch_reader heraldyx heraldyx-findings-patch.yaml")
if not ran_nothing(name, log):
    if rc != 0 or "not installed" not in out:
        bad.append(f"{name}: exited {rc} without saying it is not installed: {out.strip()[-200:]}")
    if at(log, "patch deployment heraldyx") >= 0:
        bad.append(f"{name}: patched a Deployment that is not there")
name = "reader: keyryx_patch_reader on a Deployment that is there"
rc, out, log, st = run(11, {}, LIB + "keyryx_patch_reader heraldyx heraldyx-findings-patch.yaml")
if not ran_nothing(name, log):
    if rc != 0 or at(log, "patch deployment heraldyx") < 0 or at(log, "rollout status deployment/heraldyx") < 0:
        bad.append(f"{name}: exited {rc} and did not patch and roll out heraldyx: {out.strip()[-200:]}")

if bad:
    for b in bad:
        print("FAIL keyryx-off: " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 76.")
    sys.exit(1)
print("OK: keyryx/down.sh and the opt-out leave no record-seal Job bound to the witness (a running seal is let finish,")
print("    any other deleted before the witness, then checked), and a read they cannot make stops them; 11 cases.")
PY
