#!/usr/bin/env bash
#
# Enforces invariant 98 of CLAUDE.md: every node a k3s installer prepares can run
# the stack on the Ubuntu 26.04 kernel 7.0 images, where two host defaults broke it.
#
# WHAT THIS IS ABOUT (GOTCHAS 169 and 170, the AWS run of 2026-11-27)
#
#   1. AppArmor. With kernel.apparmor_restrict_unprivileged_unconfined=1 (Ubuntu's
#      default) runc's change to the container profile is converted to a stack, so a
#      container's processes carry the label cri-containerd.apparmor.d//&unconfined.
#      containerd's default profile allows signals and ptrace only to the literal name,
#      so a container's own processes cannot signal each other: Postgres never leaves
#      recovery, and every Go binary's SIGURG preemption is denied. The upstream fix
#      (containerd#14487, merged 2026-11-16, in no containerd or k3s release as of
#      2026-11-27) adds the stacked peer to the two rules. containerd loads its default
#      profile only when no profile of that name is loaded (contrib/apparmor,
#      LoadDefaultProfile), so the installers load a host copy with those two rules
#      before k3s starts, and keep it in /etc/apparmor.d so it is loaded on every boot.
#   2. NFS. Linux 6.19+ clients ask for a directory delegation (GET_DIR_DELEGATION) in
#      the GETATTR they send when revalidating a directory; the nfs-ganesha in
#      Longhorn v1.7.2's share-manager answers OP_ILLEGAL, the client cannot decode it,
#      and the call fails with EREMOTEIO. The bus owner Job, which mounts the events
#      claim's root, ran out of retries on it. The installers turn the client feature
#      off with the nfsv4 module's own parameter (fs/nfs/delegation.c,
#      directory_delegations), now and on every boot.
#
# WHAT THIS CHECKS
#
#   A. lib/host-runtime.sh defines cri_apparmor_profile, nfs_client_modprobe and
#      host_runtime_script.
#   B. cri_apparmor_profile is containerd's default profile as k3s v1.36.2+k3s1 ships
#      it (k3s-io/containerd v2.3.2-k3s2, contrib/apparmor/template.go, rendered for an
#      unconfined daemon on a host with abi/3.0, tunables/global and abstractions/base),
#      every rule line of it present, plus exactly the two stacked-peer rules of
#      containerd#14487, and nothing wider: no //&* glob, no complain or unconfined
#      flag. `cri_apparmor_profile upstream` is the same profile without the two rules,
#      which the node uses to show the denial before it loads the fixed one.
#   C. nfs_client_modprobe is exactly `options nfsv4 directory_delegations=N`.
#   D. host_runtime_script is valid sh, installs the profile under /etc/apparmor.d and
#      loads it with apparmor_parser -r, writes the modprobe option and the live
#      parameter, and refuses (exits non-zero) when the probe signal is still denied
#      after the fixed profile is loaded.
#   E. Where apparmor_parser exists (the CI runner), both profiles parse.
#   F. Every installer (a tracked *.sh outside scripts/ and evidence/ that installs a
#      k3s server with INSTALL_K3S_VERSION) sources the library and pipes
#      host_runtime_script into a root shell on every node, in a loop over ALL_NODES,
#      with its failure stopping the install, before its first k3s install.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no library or no installer fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import os, re, shutil, subprocess, sys, tempfile

problems = []
LIB = "lib/host-runtime.sh"
NAME = "cri-containerd.apparmor.d"
STACKED = [
    f"signal (send,receive) peer={NAME}//&unconfined,",
    f"ptrace (trace,tracedby,read,readby) peer={NAME}//&unconfined,",
]
# Every rule line of containerd's template (k3s-io/containerd v2.3.2-k3s2), rendered.
UPSTREAM_RULES = [
    "abi <abi/3.0>,",
    "#include <tunables/global>",
    f"profile {NAME} flags=(attach_disconnected,mediate_deleted) {{",
    "#include <abstractions/base>",
    "network,",
    "capability,",
    "file,",
    "umount,",
    "signal (receive) peer=unconfined,",
    "signal (receive) peer=runc,",
    "signal (receive) peer=crun,",
    f"signal (send,receive) peer={NAME},",
    "deny @{PROC}/* w,",
    "deny @{PROC}/{[^1-9/],[^1-9/][^0-9/],[^1-9s/][^0-9y/][^0-9s/],[^1-9/][^0-9/][^0-9/][^0-9/]*}/** w,",
    "deny @{PROC}/sys/[^k]** w,",
    "deny @{PROC}/sys/kernel/{?,??,[^s][^h][^m]**} w,",
    "deny @{PROC}/sysrq-trigger rwklx,",
    "deny @{PROC}/kcore rwklx,",
    "deny mount,",
    "deny /sys/[^f]*/** wklx,",
    "deny /sys/f[^s]*/** wklx,",
    "deny /sys/fs/[^c]*/** wklx,",
    "deny /sys/fs/c[^g]*/** wklx,",
    "deny /sys/fs/cg[^r]*/** wklx,",
    "deny /sys/firmware/** rwklx,",
    "deny /sys/devices/virtual/powercap/** rwklx,",
    "deny /sys/kernel/security/** rwklx,",
    f"ptrace (trace,tracedby,read,readby) peer={NAME},",
    "}",
]
MODPROBE = "options nfsv4 directory_delegations=N"


def lib_call(expr):
    r = subprocess.run(["bash", "-c", f'set -u; . "./{LIB}" && {expr}'], capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def rules(text):
    out = []
    for line in text.splitlines():
        s = line.split("#", 1)[0].strip() if not line.strip().startswith("#include") else line.strip()
        # a deny rule keeps its trailing comment out; '#include' is a rule, not a comment
        if s:
            out.append(s)
    return out


# ---- A ------------------------------------------------------------------------
if not os.path.isfile(LIB):
    print(f"FAIL: {LIB} does not exist, so no installer can give a node the fixed profile or the NFS")
    print("      option, and this gate measured NOTHING. That is not a clean run.")
    sys.exit(1)
for fn in ("cri_apparmor_profile", "nfs_client_modprobe", "host_runtime_script"):
    rc, _, _ = lib_call(f"declare -F {fn} >/dev/null")
    if rc != 0:
        problems.append(f"{LIB} defines no {fn}")

# ---- B ------------------------------------------------------------------------
rc, fixed, err = lib_call("cri_apparmor_profile")
rc2, upstream, err2 = lib_call("cri_apparmor_profile upstream")
if rc != 0 or not fixed.strip():
    problems.append(f"cri_apparmor_profile printed nothing (exit {rc}): {err.strip()}")
if rc2 != 0 or not upstream.strip():
    problems.append(f"cri_apparmor_profile upstream printed nothing (exit {rc2}): {err2.strip()}")
fr, ur = rules(fixed), rules(upstream)
for want in UPSTREAM_RULES:
    if want not in fr:
        problems.append(f"the fixed profile lost containerd's rule `{want}`: it must be containerd's own profile plus two rules, not another profile")
    if want not in ur:
        problems.append(f"the upstream profile lost containerd's rule `{want}`")
for want in STACKED:
    if want not in fr:
        problems.append(f"the fixed profile has no `{want}`: a container's processes labelled {NAME}//&unconfined could not signal each other")
    if want in ur:
        problems.append(f"the upstream profile carries `{want}`, so the node's before-probe would show no denial")
extra = [r for r in fr if r not in UPSTREAM_RULES and r not in STACKED]
if extra:
    problems.append(f"the fixed profile has rules beyond containerd's and the two stacked ones: {extra}")
if fr.count(f"profile {NAME} flags=(attach_disconnected,mediate_deleted) {{") != 1:
    problems.append(f"the fixed profile does not define {NAME} exactly once with containerd's flags")
for bad in ("//&*", "//**", "complain", "flags=(unconfined", "unconfined)"):
    if bad in fixed:
        problems.append(f"the fixed profile contains `{bad}`: wider than the stacked peer containerd#14487 allows")

# ---- C ------------------------------------------------------------------------
rc, mp, _ = lib_call("nfs_client_modprobe")
if mp.strip() != MODPROBE:
    problems.append(f"nfs_client_modprobe prints {mp.strip()!r}, not {MODPROBE!r}")

# ---- D ------------------------------------------------------------------------
rc, script, err = lib_call("host_runtime_script")
if rc != 0 or not script.strip():
    problems.append(f"host_runtime_script printed nothing (exit {rc}): {err.strip()}")
else:
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as t:
        t.write(script)
    r = subprocess.run(["sh", "-n", t.name], capture_output=True, text=True)
    os.unlink(t.name)
    if r.returncode != 0:
        problems.append(f"host_runtime_script is not valid sh: {r.stderr.strip()}")
    needs = {
        r"/etc/apparmor\.d/\S+": "installs the profile under /etc/apparmor.d, so it is loaded on every boot before k3s",
        r"apparmor_parser -r": "loads (or replaces) the profile with apparmor_parser -r",
        r"/etc/modprobe\.d/\S+\.conf": "writes the nfsv4 option into /etc/modprobe.d",
        r"/sys/module/nfsv4/parameters/directory_delegations": "sets the live nfsv4 parameter",
        r"setpriv --reuid": "probes the signal as an unprivileged process, the case that stacks",
    }
    for pat, why in needs.items():
        if not re.search(pat, script):
            problems.append(f"host_runtime_script never {why} ({pat})")
    if MODPROBE not in script:
        problems.append("host_runtime_script does not write the line nfs_client_modprobe prints")
    for line in STACKED:
        if line not in script:
            problems.append("host_runtime_script does not install the profile cri_apparmor_profile prints")
            break
    sl = script.split("\n")
    stops = [i for i, x in enumerate(sl) if re.search(r'"\$after" = denied', x) and any(re.match(r"\s*exit [1-9]", y) for y in sl[i + 1:i + 4])]
    if not stops:
        problems.append("host_runtime_script does not stop when the signal is still denied after the fixed profile is loaded")

# ---- E ------------------------------------------------------------------------
parser = shutil.which("apparmor_parser")
if parser and os.path.isdir("/etc/apparmor.d/tunables"):
    for label, text in (("fixed", fixed), ("upstream", upstream)):
        with tempfile.NamedTemporaryFile("w", delete=False) as t:
            t.write(text)
        r = subprocess.run([parser, "-Q", "-K", t.name], capture_output=True, text=True)
        os.unlink(t.name)
        if r.returncode != 0:
            problems.append(f"apparmor_parser rejects the {label} profile: {r.stderr.strip()}")
    print(f"note: both profiles parsed by {parser}")
else:
    print("note: no apparmor_parser here; the profiles are parsed where one is (CI) and on every node")

# ---- F ------------------------------------------------------------------------
tracked = subprocess.run(["git", "ls-files", "*.sh"], capture_output=True, text=True).stdout.split()
installers = []
for p in tracked:
    if p.startswith(("scripts/", "evidence/")) or "/evidence/" in p or not os.path.isfile(p):
        continue
    txt = open(p).read()
    if re.search(r"^[^#\n]*INSTALL_K3S_VERSION=", txt, re.M) and re.search(r"^[^#\n]*sh -s - serv[e]r", txt, re.M):
        installers.append(p)
if not installers:
    print("FAIL: no tracked script installs a k3s server, so this measured NOTHING about the nodes.")
    sys.exit(1)

for p in installers:
    lines = open(p).read().split("\n")
    code = [(i + 1, l) for i, l in enumerate(lines) if not l.lstrip().startswith("#")]
    if not any(re.search(r'^\s*\.\s+".*lib/host-runtime\.sh"\s*$', l) for _, l in code):
        problems.append(f"{p} does not source lib/host-runtime.sh")
    first_install = next((n for n, l in code if "INSTALL_K3S_VERSION=" in l and re.search(r"\b(sh_|su_)\b", l)), None)
    calls = [(n, l) for n, l in code if re.search(r"^\s*host_runtime_script\s*\|", l)]
    if not calls:
        problems.append(f"{p} never pipes host_runtime_script to a node")
        continue
    n, l = calls[0]
    if not re.search(r'\|\s*(sh_|su_)\s+"\$n"\s+"?sh -s"?', l):
        problems.append(f"{p}:{n} pipes host_runtime_script somewhere other than a root shell on \"$n\": {l.strip()}")
    if not re.search(r"\|\|\s*die\b", l):
        problems.append(f"{p}:{n} does not stop the install when host_runtime_script fails on a node")
    loop = next((ll for nn, ll in reversed(code) if nn < n and re.match(r"\s*for n in ", ll)), "")
    if '"${ALL_NODES[@]}"' not in loop:
        problems.append(f"{p}:{n} host_runtime_script is not in a loop over every node (\"${{ALL_NODES[@]}}\")")
    if first_install is None:
        problems.append(f"{p} has no k3s install invocation this gate can place")
    elif n > first_install:
        problems.append(f"{p}:{n} host_runtime_script runs after the first k3s install (line {first_install}): containerd would load its own profile first")

if problems:
    for x in problems:
        print("FAIL:", x)
    sys.exit(1)
print(f"OK: {len(installers)} installer(s) give every node containerd's profile with the stacked peer and the NFS client without directory delegations, before k3s")
PY
