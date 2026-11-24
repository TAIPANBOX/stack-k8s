#!/usr/bin/env bash
#
# Enforces CLAUDE.md invariant 95: the gateway's spend reaches the FinOps console on a cluster. The
# gateway pod's focus-export writes one FOCUS CSV into focus/gateway on the events claim, the bus
# owner makes that directory, and the costcrew console mounts focus/ read only and reads it with
# -focus-dir and -focus-replace-generated.
#
# WHY
#
# Until 2026-11-23 focus-export wrote into an emptyDir of its own and the costcrew console set no
# -focus-dir, so beside a gateway that had priced real agents the console's AI pages showed the
# generated estate it starts with. Nothing was red: every container ran, and the only trace was a
# CSV in a scratch volume nobody read. Each fault below is silent the same way.
#
# WHAT THIS CHECKS
#
#   1. manifests/11-bus.yaml: the owner makes focus/ (20000:10003 2751) and focus/gateway/
#      (20000:20010 2775) before it writes streams/.layout, and writes nothing below focus/.
#   2. manifests/10-planes.yaml, the gateway pod: focus-export mounts the events claim at subPath
#      focus/gateway, read-write, and its script's `out` is that mount; the pod's bus-ready waits for
#      focus/gateway to be the owner's; no `focus` emptyDir is left.
#   3. The script itself, lifted and run against a stub `tokenfuse-gateway`: it exports before it first
#      sleeps, writes `.focus-gateway.partial` and renames it to `focus-gateway.csv` whole, keeps the
#      last good file on a window that exports nothing, prints the tool's words when it fails, and
#      never leaves the partial file behind.
#   4. manifests/49-costcrew.yaml, the Deployment: the console mounts subPath focus read only, its
#      -focus-dir is that mount plus /gateway, it passes -focus-replace-generated and no
#      -focus-dir-openai (one door here), its pod is in group 10003 and not in 20010, its bus-ready
#      waits for focus/gateway, and its image is costcrew v0.7.0 or later (the first that reads
#      -focus-dir). The crew CronJob mounts no focus.
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, "scripts/lib")
import miniyaml

bad = []
BUS, PLANES, CC = "manifests/11-bus.yaml", "manifests/10-planes.yaml", "manifests/49-costcrew.yaml"


def docs(path):
    try:
        return miniyaml.load_all(open(path).read())
    except OSError:
        return None


def obj(ds, kind, name):
    for d in ds or []:
        if isinstance(d, dict) and d.get("kind") == kind and (d.get("metadata") or {}).get("name") == name:
            return d
    return None


def pod(d):
    spec = (d.get("spec") or {})
    if d.get("kind") == "CronJob":
        spec = ((spec.get("jobTemplate") or {}).get("spec") or {})
    return ((spec.get("template") or {}).get("spec") or {})


def waits_for_focus(p, where):
    inits = p.get("initContainers") or []
    cmd = " ".join(str(x) for x in (inits[0].get("command") or [])) if inits else ""
    if not re.search(r'stat -c %u:%g:%a /bus/focus/gateway[^"]*"\s*=\s*20000:20010:2775\b', cmd.replace('\\"', '"')):
        bad.append(f"{where}: its bus-ready does not wait for focus/gateway to be the owner's, 20000:20010:2775, so kubelet "
                   "can make it as root first, or the wait passes between the owner's mkdir and its chgrp")


# ---- 1. the owner ----
bus = docs(BUS)
script = None
cm = obj(bus, "ConfigMap", "bus-owner") if bus else None
if cm is None:
    bad.append(f"{BUS}: no ConfigMap bus-owner, so the owner is measured NOTHING")
else:
    script = (cm.get("data") or {}).get("bus-owner.sh", "")
    live = "\n".join(l for l in script.split("\n") if not l.lstrip().startswith("#"))
    lay = live.find("> \"$S/.layout.tmp\"")
    for path, grp, mode in (("$B/focus", "10003", "2751"), ("$B/focus/gateway", "20010", "2775")):
        m = re.search(r'^\s*own_dir "' + re.escape(path) + r'" (\d+) (\d+)\s*$', live, re.M)
        if not m:
            bad.append(f"{BUS}: the owner does not make {path[3:]}/")
            continue
        if (m.group(1), m.group(2)) != (grp, mode):
            bad.append(f"{BUS}: {path[3:]}/ is made {m.group(1)} {m.group(2)}, not {grp} {mode}")
        if lay < 0 or m.start() > lay:
            bad.append(f"{BUS}: {path[3:]}/ is made after streams/.layout, so a pod can start before it exists")
    if re.search(r'(>|place|own_file|chgrp|chmod|mv)[^\n]*"\$B/focus/', live.replace('own_dir "$B/focus/gateway"', "")):
        bad.append(f"{BUS}: the owner writes or re-owns something below focus/, where a planted link would turn its hand (GOTCHAS 164)")

# ---- 2. the gateway pod ----
planes = docs(PLANES)
gw = obj(planes, "Deployment", "tokenfuse-gateway") if planes else None
fe_script = None
if gw is None:
    bad.append(f"{PLANES}: no Deployment tokenfuse-gateway, so the export is measured NOTHING")
else:
    p = pod(gw)
    fe = next((c for c in p.get("containers") or [] if c.get("name") == "focus-export"), None)
    if fe is None:
        bad.append(f"{PLANES}: the gateway pod has no focus-export container, so the export is measured NOTHING")
    else:
        mounts = [m for m in fe.get("volumeMounts") or [] if m.get("name") == "events"]
        out_mount = next((m for m in mounts if m.get("subPath") == "focus/gateway"), None)
        if out_mount is None or out_mount.get("readOnly"):
            bad.append(f"{PLANES}: focus-export does not mount subPath focus/gateway read-write")
        fe_script = "\n".join(str(a) for a in fe.get("args") or [])
        gwc = next((c for c in p.get("containers") or [] if c.get("name") == "gateway"), None)
        gbin = os.path.basename(str((gwc or {}).get("command", [""])[0])) if gwc else ""
        called = re.findall(r"\$\((\S+) focus-export ", fe_script)
        if not gbin:
            bad.append(f"{PLANES}: the gateway container names no command, so the binary focus-export must call is unknown")
        elif called != [gbin]:
            bad.append(f"{PLANES}: focus-export calls {called}, not {gbin!r}, the binary the gateway container runs; a name the "
                       "image does not ship fails every window as a quiet one")
        fsc = fe.get("securityContext") or {}
        psc = p.get("securityContext") or {}
        if (fsc.get("runAsUser", psc.get("runAsUser")), fsc.get("runAsGroup", psc.get("runAsGroup"))) != (20010, 20010):
            bad.append(f"{PLANES}: focus-export does not run as 20010:20010, the gateway's identity that focus/gateway admits")
        m = re.search(r"^\s*out=(\S+)\s*$", fe_script, re.M)
        if not m:
            bad.append(f"{PLANES}: focus-export's script names no out= directory")
        elif out_mount is not None and m.group(1) != out_mount.get("mountPath"):
            bad.append(f"{PLANES}: focus-export writes to {m.group(1)}, not to its focus/gateway mount at {out_mount.get('mountPath')}")
    if any(v.get("name") == "focus" and "emptyDir" in v for v in p.get("volumes") or []):
        bad.append(f"{PLANES}: a `focus` emptyDir is still in the gateway pod, where nothing outside it can read an export")
    waits_for_focus(p, f"{PLANES}: Deployment tokenfuse-gateway")

# ---- 3. the script, run ----
if fe_script:
    with tempfile.TemporaryDirectory() as t:
        tr, out, binp = os.path.join(t, "traces"), os.path.join(t, "out"), os.path.join(t, "bin")
        for d in (tr, out, binp):
            os.makedirs(d)
        os.makedirs(os.path.join(tr, "gateway"))
        stub = os.path.join(binp, gbin or "tokenfuse")
        # The stub answers from a queue of outcomes, one per call: ok:<rows> writes a CSV; idle and
        # fail:<words> exit non-zero, leaving a partial behind on purpose to see it removed.
        open(stub, "w").write("""#!/bin/sh
q="$STUB_DIR/queue"; n=$(cat "$STUB_DIR/n" 2>/dev/null || echo 0); n=$((n+1)); echo $n >"$STUB_DIR/n"
what=$(sed -n "${n}p" "$q")
outp=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && outp="$2"; shift; done
echo "export $n $what" >>"$STUB_DIR/log"
case "$what" in
  ok:*) printf 'BilledCost,x_run_id\\n' >"$outp"; i=0; while [ $i -lt "${what#ok:}" ]; do echo "1.00,r$n-$i" >>"$outp"; i=$((i+1)); done; exit 0 ;;
  idle) echo half >"$outp"; echo "error: no calls found in the trace" >&2; exit 1 ;;
  fail:*) echo half >"$outp"; echo "${what#fail:}" >&2; exit 1 ;;
esac
exit 3
""")
        os.chmod(stub, 0o755)
        body = fe_script.replace("/var/lib/stack/traces", tr).replace("/var/lib/stack/focus/gateway", out)
        # sleep ends the run after the third window, and records what was on disk when it was asked.
        harness = f"""umask 077
sleep() {{ n=$(cat "$STUB_DIR/s" 2>/dev/null || echo 0); n=$((n+1)); echo $n >"$STUB_DIR/s"
  echo "sleep $n $1 csv=$(cat '{out}/focus-gateway.csv' 2>/dev/null | wc -l | tr -d ' ') partial=$(ls -A '{out}' | grep -c partial)" >>"$STUB_DIR/log"
  [ "$n" -lt 3 ] || exit 0; }}
{body}
"""
        open(os.path.join(t, "queue"), "w").write("ok:2\nidle\nfail:permission denied: /var/lib/stack/traces\n")
        env = dict(os.environ, PATH=binp + ":" + os.environ["PATH"], STUB_DIR=t, FOCUS_EXPORT_INTERVAL="900")
        r = subprocess.run(["sh", "-c", harness], capture_output=True, text=True, env=env, timeout=30)
        log = open(os.path.join(t, "log")).read() if os.path.exists(os.path.join(t, "log")) else ""
        lines = log.split("\n")
        if not lines or not lines[0].startswith("export 1"):
            bad.append(f"{PLANES}: focus-export sleeps before its first export, so a fresh cluster shows nothing for an interval: {lines[:2]}")
        if "sleep 1 900 csv=3 partial=0" not in log:
            bad.append(f"{PLANES}: after a window with calls the folder does not hold focus-gateway.csv whole (header and both rows) and no partial: {log!r}")
        if "sleep 2 900 csv=3 partial=0" not in log:
            bad.append(f"{PLANES}: an idle window does not keep the last good file, or leaves its partial behind: {log!r}")
        if "sleep 3 900 csv=3 partial=0" not in log:
            bad.append(f"{PLANES}: a failed window does not keep the last good file, or leaves its partial behind: {log!r}")
        csvp = os.path.join(out, "focus-gateway.csv")
        if os.path.exists(csvp) and (os.stat(csvp).st_mode & 0o777) != 0o644:
            bad.append(f"{PLANES}: under a umask of 077 the export is left {oct(os.stat(csvp).st_mode & 0o777)}, not 0644, so the console, which reads it through other, cannot")
        if "permission denied" not in r.stdout:
            bad.append(f"{PLANES}: a failed export is not printed in the tool's own words, so a fault reads as a quiet window: {r.stdout[-300:]!r}")
        if re.search(r'--out "\$csv"|--out "\$out/[^"]*\.csv"', fe_script) or not re.search(r'part="\$out/\.[^"]*\.partial"', fe_script):
            bad.append(f"{PLANES}: focus-export writes straight to a name the console reads, so it can read half an export")

# ---- 4. the console ----
cc = docs(CC)
dep = obj(cc, "Deployment", "costcrew") if cc else None
if dep is None:
    bad.append(f"{CC}: no Deployment costcrew, so the reader is measured NOTHING")
else:
    p = pod(dep)
    c = next((c for c in p.get("containers") or [] if c.get("name") == "costcrew"), None)
    if c is None:
        bad.append(f"{CC}: no costcrew container, so the reader is measured NOTHING")
    else:
        args = [str(a) for a in c.get("args") or []]
        mount = next((m for m in c.get("volumeMounts") or [] if m.get("name") == "events" and m.get("subPath") == "focus"), None)
        if mount is None:
            bad.append(f"{CC}: the console does not mount subPath focus, so it cannot see the export")
        elif not mount.get("readOnly"):
            bad.append(f"{CC}: the console mounts focus read-write; it only reads it")
        fd = args[args.index("-focus-dir") + 1] if "-focus-dir" in args and args.index("-focus-dir") + 1 < len(args) else None
        if fd is None:
            bad.append(f"{CC}: the console has no -focus-dir, so it reads no spend")
        elif mount is not None and fd != mount.get("mountPath", "").rstrip("/") + "/gateway":
            bad.append(f"{CC}: -focus-dir is {fd}, not the gateway's folder {mount.get('mountPath')}/gateway, so the console imports nothing")
        if "-focus-replace-generated" not in args:
            bad.append(f"{CC}: no -focus-replace-generated, so every import is refused while the generated estate is there and the AI pages keep showing it")
        if "-focus-dir-openai" in args:
            bad.append(f"{CC}: -focus-dir-openai names a door this launcher does not run")
        img = str(c.get("image", ""))
        mv = re.search(r":v(\d+)\.(\d+)\.(\d+)", img)
        if not mv or tuple(map(int, mv.groups())) < (0, 7, 0):
            bad.append(f"{CC}: the console image {img} is older than costcrew v0.7.0, the first that reads -focus-dir")
    sc = p.get("securityContext") or {}
    groups = {sc.get("runAsGroup"), sc.get("fsGroup")} | set(sc.get("supplementalGroups") or [])
    if 10003 not in groups:
        bad.append(f"{CC}: the console's pod is not in group 10003, so it cannot enter focus/")
    if 20010 in groups:
        bad.append(f"{CC}: the console's pod carries the gateway's group 20010, so it could write the export and tokenfuse.ndjson")
    waits_for_focus(p, f"{CC}: Deployment costcrew")
    crew = obj(cc, "CronJob", "costcrew-crew")
    if crew is not None:
        for cn in pod(crew).get("containers") or []:
            if any(m.get("subPath") == "focus" for m in cn.get("volumeMounts") or []):
                bad.append(f"{CC}: the crew CronJob mounts focus; the import lands in the store, the crew needs no export")

# ---- 5. every launcher lets the owner run on every apply ----
for lp in ("deploy.sh", "cloud/gcp/deploy-gcp.sh", "cloud/aws/deploy-aws.sh"):
    try:
        ltext = open(lp).read()
    except OSError:
        bad.append(f"{lp} is absent: its owner run is measured NOTHING")
        continue
    lines = [l for l in ltext.split("\n") if not l.lstrip().startswith("#")]
    apply_line = 'k_ "apply' + ' -k /root/stack-k8s/manifests"'  # split so deploy-flags-agree.sh does not take this for a launcher
    ia = next((i for i, l in enumerate(lines) if apply_line in l), None)
    idel = next((i for i, l in enumerate(lines) if 'delete job bus-owner --ignore-not-found' in l), None)
    if ia is None:
        bad.append(f"{lp}: no apply of the manifests found, so its owner run is measured NOTHING")
    elif idel is None or idel > ia:
        bad.append(f"{lp}: the finished bus-owner Job is not deleted before the first apply, so a re-run within ten minutes "
                   "never makes focus/ and the pods that wait for it wait for ever")

if bad:
    for b in bad:
        print("FAIL " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 95.")
    sys.exit(1)
print("OK: focus-export writes one whole FOCUS CSV into focus/gateway, which the bus owner makes; the costcrew "
      "console reads it read only with -focus-dir and -focus-replace-generated; the script was run against a stub.")
PY
