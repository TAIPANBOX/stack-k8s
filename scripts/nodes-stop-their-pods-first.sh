#!/usr/bin/env bash
#
# Enforces invariant 46 of CLAUDE.md: a node that is shut down stops its pods
# before its network, and verify.sh does not count the pods that stop left behind.
#
# WHAT THIS IS ABOUT
#
# k3s's unit stops with KillMode=process, so on a reboot the containers outlive the
# kubelet, and systemd brings the network down while a pod is still writing to the
# shared RWX (NFS) volume. On GCP on 2026-10-14 a reboot of a server hung 7 minutes
# in systemd-shutdown, "Waiting for process (tokenfuse)", and took 8m19s instead of
# about one. The kubelet's graceful node shutdown is what stops the pods first, and
# it is off unless configured: a shutdownGracePeriod of zero, which is k3s's default.
#
# THE TWO THINGS THAT HAVE TO BE TRUE, both written by the installers on every node:
#
#   1. The kubelet has a shutdown period. A KubeletConfiguration drop-in in the
#      directory k3s always passes to the kubelet as --config-dir
#      (<DataDir>/agent/etc/kubelet.conf.d, k3s source pkg/daemons/agent,
#      kubeletArgsAndConfig), with shutdownGracePeriod 60s and
#      shutdownGracePeriodCriticalPods 15s: pods get 45 s, critical pods 15 s.
#   2. systemd-logind waits for that long. The kubelet holds a delay inhibitor, and
#      systemd does not wait longer than InhibitDelayMaxSec for it (5 s by default,
#      logind.conf.in). A drop-in in /etc/systemd/logind.conf.d raises it above the
#      period, and the installer restarts logind so the drop-in is read now.
#
# WHAT THIS CHECKS, over every installer (a tracked *.sh, outside scripts/, that
# installs k3s with INSTALL_K3S_VERSION):
#
#   A. graceful_shutdown_conf is a KubeletConfiguration with exactly those two
#      fields, the critical period below the total, the total at most 120 s, and
#      the pods' window (total minus critical) at least as long as the slowest pod
#      stop a manifest here allows (terminationGracePeriodSeconds, 30 s when none
#      is set, plus 5 s). The document is the same in every installer.
#   B. logind_conf raises InhibitDelayMaxSec to at least the total, and is the same
#      in every installer.
#   C. put_graceful_shutdown writes both files and restarts systemd-logind, and runs
#      on the node just above every k3s install invocation for that node: the first
#      server, every further server, every agent.
#   D. No install invocation passes --kubelet-arg=config-dir=, which would replace
#      the directory k3s uses for the drop-in.
#   E. After the last install, each node is asked whether the kubelet holds its
#      systemd-logind inhibitor, so a node that cannot shut down gracefully is named
#      at install time.
#   F. verify.sh's pod count, lifted between its `# pods:` markers and run over a
#      stand-in kubectl: a pod stopped by a node shutdown is noted and not counted,
#      a crash-looping pod is still counted, a finished Job pod is not.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no installer, no install invocation, or
# no pod block in verify.sh is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import glob, os, re, subprocess, sys, tempfile

problems = []
tracked = subprocess.run(["git", "ls-files", "*.sh"], capture_output=True, text=True).stdout.split()


def code_lines(path):
    return [(i + 1, l) for i, l in enumerate(open(path).read().split("\n")) if not l.lstrip().startswith("#")]


installers = []
for p in tracked:
    if p.startswith("scripts/") or not os.path.isfile(p):
        continue
    live = "\n".join(l for _, l in code_lines(p))
    if re.search(r"sh -s - (serv[e]r|agen[t])", live) and "INSTALL_K3S_VERSION=" in live:
        installers.append(p)
if not installers:
    print("FAIL: no tracked script installs k3s, so this measured NOTHING about graceful node shutdown.")
    sys.exit(1)

# the slowest pod stop a manifest here allows: 30 s when none is set
grace = [30]
for f in glob.glob("manifests/*.yaml"):
    for m in re.finditer(r"(?m)^[^#\n]*terminationGracePeriodSeconds:\s*(\d+)", open(f).read()):
        grace.append(int(m.group(1)))
need = max(grace) + 5

KUBELET_WANT = [
    "apiVersion: kubelet.config.k8s.io/v1beta1",
    "kind: KubeletConfiguration",
    "shutdownGracePeriod: 60s",
    "shutdownGracePeriodCriticalPods: 15s",
]
LOGIND_WANT = ["[Login]", "InhibitDelayMaxSec=180"]


def func_doc(text, name):
    m = re.search(r"(?ms)^" + re.escape(name) + r"\(\) \{[^\n]*\n(.*?)\n\}", text)
    if not m:
        return None
    return re.findall(r"(?m)^\s*'([^']*)'\s*\\?\s*$", m.group(1)), m.group(1)


docs_kubelet, docs_logind = {}, {}
for p in installers:
    total = None
    text = "\n".join(l for _, l in code_lines(p))
    k = func_doc(text, "graceful_shutdown_conf")
    if not k:
        problems.append(f"{p}: installs k3s and defines no graceful_shutdown_conf, so its nodes reboot with their pods still running")
    else:
        doc = k[0]
        docs_kubelet[p] = doc
        if doc != KUBELET_WANT:
            problems.append(f"{p}: graceful_shutdown_conf is not the KubeletConfiguration this gate holds:\n      " + "\n      ".join(doc))
        # the window is checked whatever the document says, so each rule has its own finding
        tm = re.search(r"shutdownGracePeriod: (\d+)s", "\n".join(doc))
        cm = re.search(r"shutdownGracePeriodCriticalPods: (\d+)s", "\n".join(doc))
        if tm and cm:
            total = int(tm.group(1))
            crit = int(cm.group(1))
            if not crit < total:
                problems.append(f"{p}: the critical period ({crit} s) is not below the total ({total} s)")
            if total > 120:
                problems.append(f"{p}: a shutdown may wait {total} s for pods, more than 120 s")
            if total - crit < need:
                problems.append(f"{p}: our workloads get {total - crit} s to stop at a shutdown, less than the {need} s a pod here may take (30 s default and 5 s)")
    lg = func_doc(text, "logind_conf")
    if not lg:
        problems.append(f"{p}: defines no logind_conf, so systemd-logind waits 5 s for the kubelet and the shutdown period is cut short")
    else:
        ldoc = lg[0]
        docs_logind[p] = ldoc
        if ldoc != LOGIND_WANT:
            problems.append(f"{p}: logind_conf is not the drop-in this gate holds: " + " / ".join(ldoc))
        elif total is not None and total > int(re.search(r"InhibitDelayMaxSec=(\d+)", ldoc[1]).group(1)):
            problems.append(f"{p}: systemd-logind waits {re.search(r'InhibitDelayMaxSec=(\d+)', ldoc[1]).group(1)} s for the kubelet, less than the {total} s shutdown period")

    pg = func_doc(text, "put_graceful_shutdown")
    if not pg:
        problems.append(f"{p}: defines no put_graceful_shutdown")
    else:
        body = pg[1]
        for need_s in ("graceful_shutdown_conf", "logind_conf", "/etc/systemd/logind.conf.d", "systemctl restart systemd-logind"):
            if need_s not in body:
                problems.append(f"{p}: put_graceful_shutdown does not {need_s!r}, so the node is not given the shutdown setting")

    lines = dict(code_lines(p))
    installs = [(n, l) for n, l in lines.items() if re.search(r'(?:sh_|su_) ("\$FIRST"|"\$n") "INSTALL_K3S_VERSION=', l)]
    if not installs:
        problems.append(f"{p}: no k3s install invocation found, so this cannot tell where the file has to be written")
        continue
    for n, l in sorted(installs):
        node = re.search(r'(?:sh_|su_) ("\$FIRST"|"\$n") ', l).group(1)
        prev = [lines[k] for k in range(max(1, n - 3), n) if k in lines]
        if not any(re.match(r"\s*put_graceful_shutdown " + re.escape(node) + r"\s*$", x) for x in prev):
            problems.append(f"{p}:{n}: installs k3s on {node} without writing the graceful-shutdown files onto it just above")
        body, k = [l], n
        while "get.k3s.io" not in lines.get(k, "") and k < n + 30:
            k += 1
            body.append(lines.get(k, ""))
        if any(re.search(r"--kubelet-arg=config-dir\b", x) for x in body):
            problems.append(f"{p}:{n}: the k3s install on {node} passes --kubelet-arg=config-dir, which replaces the directory k3s reads the shutdown file from")
    last = max(n for n, _ in installs)
    checks = [n for n, l in lines.items() if re.search(r"systemd-inhibit --list[^\"]*\| grep -qi kubelet", l)]
    if not checks:
        problems.append(f"{p}: never asks the nodes whether the kubelet holds its shutdown inhibitor, so a node without systemd-logind goes unnamed")
    elif min(checks) < last:
        problems.append(f"{p}: asks for the inhibitor at line {min(checks)}, before its last k3s install at line {last}")

if len({tuple(d) for d in docs_kubelet.values()}) > 1:
    problems.append("graceful_shutdown_conf differs between installers: " + ", ".join(sorted(docs_kubelet)))
if len({tuple(d) for d in docs_logind.values()}) > 1:
    problems.append("logind_conf differs between installers: " + ", ".join(sorted(docs_logind)))

# F. verify.sh's pod count, run over a stand-in kubectl
v = open("verify.sh").read() if os.path.isfile("verify.sh") else ""
m = re.search(r"(?ms)^# pods: begin\n(.*?)^# pods: end\n", v)
if not m:
    problems.append("verify.sh has no `# pods: begin` ... `# pods: end` block, so its pod count was not run")
else:
    table = (
        "api-1 1/1 Running 0 1h\n"
        "crash-1 0/1 CrashLoopBackOff 7 1h\n"
        "job-1 0/1 Completed 0 1h\n"
        "gone-1 0/1 Error 0 1h\n"
    )
    phases = "api-1 Running \ncrash-1 Running \njob-1 Succeeded \ngone-1 Failed Terminated\n"
    script = (
        "set -uo pipefail\nNS=agent-stack\npass=0; fail=0; warn=0\n"
        "ok() { echo \"OK $*\"; }\nbad() { echo \"BAD $*\"; }\nnote() { echo \"NOTE $*\"; }\n"
        "kc() { case \"$*\" in *--no-headers*) printf '%s' \"$TABLE\" ;; *jsonpath*) printf '%s' \"$PHASES\" ;; *) return 3 ;; esac; }\n"
        + m.group(1)
    )
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                       env=dict(os.environ, TABLE=table, PHASES=phases))
    out = r.stdout
    if "BAD 1 pod(s)" not in out:
        problems.append(f"verify.sh's pod count over a crash-looping pod, a finished Job and a pod a node shutdown stopped did not report exactly one bad pod: {out.strip()[:200]!r}")
    if "NOTE 1 pod(s) stopped by a node shutdown" not in out or "gone-1" not in out:
        problems.append(f"verify.sh does not note the pod a node shutdown stopped, by name: {out.strip()[:200]!r}")

if problems:
    for p in problems:
        print("FAIL: " + p)
    print()
    print(f"{len(problems)} problem(s). See CLAUDE.md invariant 46.")
    sys.exit(1)
print(f"OK: {len(installers)} installer(s) write the same shutdown period (60 s, 15 s critical) and the same")
print(f"    systemd-logind delay (180 s) onto every node before k3s, and ask each node for the kubelet's inhibitor;")
print(f"    workloads get at least {need} s. verify.sh notes a pod a shutdown stopped and still counts a crash loop.")
PY
