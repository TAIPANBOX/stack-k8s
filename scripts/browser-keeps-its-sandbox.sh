#!/usr/bin/env bash
#
# Enforces invariant 84 of CLAUDE.md: Chromium keeps its own sandbox on a cluster. The browser
# container runs under a Localhost seccomp profile that is stack-single's filter in the form a node
# reads, every installer writes that file to every node before k3s starts there, and nothing turns
# the sandbox off.
#
# WHAT THIS IS ABOUT
#
# A renderer is the process a hostile page runs in. With Chromium's sandbox off, an exploit there
# runs as the container's user and can open sockets directly: egress that never passes scopyx's
# proxy and never reaches its journal (GOTCHAS 83). The runtime's default filter refuses the user
# namespace the sandbox needs, Pod Security `restricted` refuses Unconfined (GOTCHAS 84), and
# `restricted` admits a Localhost profile, which the kubelet reads from a file on the node.
#
# WHAT THIS CHECKS
#
#   A. No tracked YAML sets SCOPYX_CHROMIUM_NO_SANDBOX in code (a comment may name it). Every
#      manifest that runs the browser image gives that container
#      `seccompProfile: { type: Localhost, localhostProfile: <the name lib/browser-seccomp.sh
#      writes> }`, and nothing in it is Unconfined, for seccomp or for AppArmor.
#   B. seccomp/chromium-v1.docker.json is stack-single's file byte for byte (the digest
#      stack-single's containers-carry-the-baseline.sh pins); seccomp/chromium-v1.json is exactly
#      what seccomp/resolve.py prints from it, and carries the digest pinned here, so a changed
#      profile needs a new name; it has none of Docker's own keys (archMap, includes, excludes),
#      which containerd drops without a word (GOTCHAS 161); none of the calls Docker allows only to
#      a container holding CAP_SYS_ADMIN is allowed without a condition; and the three calls it
#      adds are the three stack-single measured, with their masks.
#   C. lib/browser-seccomp.sh writes seccomp/chromium-v1.json (not the Docker file) under the
#      kubelet's seccomp root, at the name the manifest asks for; every installer (a tracked *.sh
#      outside scripts/ that installs k3s) sources it and calls browser_seccomp_put, stopping on a
#      failure, on the node just above every k3s install invocation for that node; and the
#      function, run with a stand-in helper, sends the file's exact bytes and moves them into
#      place.
#   D. features/the-browser-keeps-its-sandbox.feature binds each scenario to cases in
#      scripts/gates-have-teeth.sh, both ways.
#   E. Every recorded run in evidence/browser-sandbox-k3s/ ends RUN_EXIT=0 with no failure, and
#      there is one for each architecture the image is published for.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no manifest running the browser, no profile, no
# installer, no feature or no recorded run is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import hashlib, json, os, re, subprocess, sys, tempfile

problems = []
def bad(why):
    problems.append(why)

# stack-single's scripts/containers-carry-the-baseline.sh pins this digest for its own copy.
SOURCE_SHA = "744d959fbe18e8187de3be9152da259b2a553cdff01b6b969b4f96af2e5ce74e"
# What seccomp/resolve.py prints from it. A different profile is a different name (chromium-v2).
NODE_SHA = "cc2644c8fd5c4dad925d4ead48f33aa681dc5555ef97b3ec616436d76c50a153"
SOURCE = "seccomp/chromium-v1.docker.json"
NODE = "seccomp/chromium-v1.json"
LIB = "lib/browser-seccomp.sh"
FEATURE = "features/the-browser-keeps-its-sandbox.feature"
BROWSER_IMAGE = re.compile(r"image:\s*ghcr\.io/taipanbox/scopyx:v[^\s@]*-chromium@sha256:[0-9a-f]{64}")
tracked = subprocess.run(["git", "ls-files"], capture_output=True, text=True).stdout.split()

def code(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))

def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()

# ---- C first: the name the installers write --------------------------------------------------
name = root = src = None
if not os.path.isfile(LIB):
    bad(f"{LIB} is not there, so no installer writes the browser's profile and this measured NOTHING about where it goes")
else:
    lib = code(open(LIB).read())
    m = re.search(r"^BROWSER_SECCOMP_NAME=(\S+)$", lib, re.M); name = m and m.group(1)
    m = re.search(r"^BROWSER_SECCOMP_ROOT=(\S+)$", lib, re.M); root = m and m.group(1)
    m = re.search(r'^BROWSER_SECCOMP_FILE=.*/(seccomp/[^"/]+)"$', lib, re.M); src = m and m.group(1)
    if not name:
        bad(f"{LIB} names no BROWSER_SECCOMP_NAME")
    if root != "/var/lib/kubelet/seccomp":
        bad(f"{LIB} writes under {root}, not the kubelet's seccomp root /var/lib/kubelet/seccomp, so the kubelet never finds the file")
    if src != NODE:
        bad(f"{LIB} sends {src} to the nodes, not {NODE}, the profile resolved for a node")

# ---- A. the manifests ------------------------------------------------------------------------
for path in tracked:
    if not path.endswith((".yaml", ".yml")) or not os.path.isfile(path):
        continue
    if re.search(r"SCOPYX_CHROMIUM_NO_SANDBOX", code(open(path).read())):
        bad(f"{path} sets SCOPYX_CHROMIUM_NO_SANDBOX, which turns Chromium's sandbox off")

subjects = [p for p in tracked if p.startswith("manifests/") and p.endswith(".yaml") and os.path.isfile(p)
            and BROWSER_IMAGE.search(code(open(p).read()))]
if not subjects:
    bad("no manifest runs the browser image, so this measured NOTHING about its sandbox")
for path in subjects:
    lines = open(path).read().split("\n")
    live = code("\n".join(lines))
    if re.search(r"(?i)type:\s*Unconfined", live):
        bad(f"{path}: something in it is Unconfined, which restricted refuses and which would take a filter away")
    if re.search(r"(?i)appArmorProfile", live) or re.search(r"container\.apparmor\.security\.beta\.kubernetes\.io", live):
        bad(f"{path}: names an AppArmor profile; the measured setting is the runtime's default, set nowhere")
    # each container block: from `- name:` at the containers' indent to the next one, or out of the list
    for i, l in enumerate(lines):
        if not BROWSER_IMAGE.search(l) or l.lstrip().startswith("#"):
            continue
        start = i
        while start > 0 and not re.match(r"^\s*- name: ", lines[start]):
            start -= 1
        indent = len(lines[start]) - len(lines[start].lstrip())
        end = i + 1
        while end < len(lines):
            s = lines[end]
            if s.strip() and not s.lstrip().startswith("#") and len(s) - len(s.lstrip()) <= indent:
                break
            end += 1
        block = code("\n".join(lines[start:end]))
        found = re.findall(r"seccompProfile:\s*\{\s*type:\s*(\w+)(?:,\s*localhostProfile:\s*([^\s}]+))?\s*\}", block)
        if not found:
            bad(f"{path}:{start + 1}: the browser container sets no seccompProfile of its own, so it runs the pod's, which refuses Chromium's sandbox")
        elif found != [("Localhost", name or "")]:
            bad(f"{path}:{start + 1}: the browser container's seccompProfile is {found}, not Localhost {name}, the profile the installers write")

# ---- B. the profile --------------------------------------------------------------------------
if not os.path.isfile(SOURCE) or not os.path.isfile(NODE):
    bad(f"{SOURCE} or {NODE} is not there, so this measured NOTHING about the filter")
else:
    if sha(SOURCE) != SOURCE_SHA:
        bad(f"{SOURCE} is not stack-single's chromium-v1.json byte for byte (sha256 {sha(SOURCE)[:12]}, pinned {SOURCE_SHA[:12]}): the two stacks would run different filters under one name")
    printed = subprocess.run([sys.executable, "-I", "seccomp/resolve.py", SOURCE], capture_output=True, text=True)
    if printed.returncode != 0:
        bad("seccomp/resolve.py refused the source: " + printed.stderr.strip())
    elif printed.stdout != open(NODE).read():
        bad(f"{NODE} is not what seccomp/resolve.py prints from {SOURCE}")
    if sha(NODE) != NODE_SHA:
        bad(f"{NODE} changed and kept its name (sha256 {sha(NODE)[:12]}, pinned {NODE_SHA[:12]}): the kubelet reads the file at each container start, so a running browser would change its filter at its next restart with no change to the pod; a new profile is a new name")
    p = json.load(open(NODE))
    d = json.load(open(SOURCE))
    extra = set(p) - {"defaultAction", "defaultErrnoRet", "architectures", "syscalls"}
    if extra:
        bad(f"{NODE} carries {sorted(extra)}, Docker's own keys, which containerd drops without a word")
    for r in p.get("syscalls", []):
        extra = set(r) - {"names", "action", "errnoRet", "args"}
        if extra:
            bad(f"{NODE}: a rule for {r.get('names')} carries {sorted(extra)}, a condition containerd drops, so the rule applies without it")
    if p.get("defaultAction") != "SCMP_ACT_ERRNO":
        bad(f"{NODE}: the default action is {p.get('defaultAction')}, not SCMP_ACT_ERRNO")
    if sorted(set(p.get("architectures", [])) & {"SCMP_ARCH_X86_64", "SCMP_ARCH_AARCH64"}) != ["SCMP_ARCH_AARCH64", "SCMP_ARCH_X86_64"]:
        bad(f"{NODE}: does not cover both amd64 and arm64, the two the browser image is published for")
    admin_only = set()
    for r in d.get("syscalls", []):
        if "CAP_SYS_ADMIN" in (r.get("includes") or {}).get("caps", []) and r.get("action") == "SCMP_ACT_ALLOW":
            admin_only |= set(r["names"])
    if not admin_only:
        bad(f"{SOURCE} has no rule for a container holding CAP_SYS_ADMIN, so the widening check measured NOTHING")
    for r in p.get("syscalls", []):
        if r.get("action") == "SCMP_ACT_ALLOW" and not r.get("args"):
            leak = sorted(admin_only & set(r["names"]))
            if leak:
                bad(f"{NODE}: allows {leak} without a condition, calls Docker allows only to a container holding CAP_SYS_ADMIN")
    def rule(n):
        return [r for r in p.get("syscalls", []) if r.get("names") == [n] and r.get("action") == "SCMP_ACT_ALLOW"]
    if not any(not r.get("args") for r in rule("chroot")):
        bad(f"{NODE}: does not allow chroot, which Chromium's sandbox needs (Check failed: sys_chroot)")
    want = {"clone": 0x0E020000, "unshare": 0xEFFFFFFF}
    for n, mask in want.items():
        masked = [r for r in rule(n) if r.get("args")]
        ok = [r for r in masked if r["args"] == [{"index": 0, "value": mask, "op": "SCMP_CMP_MASKED_EQ"}]]
        if not ok:
            bad(f"{NODE}: {n} is not held to the mask stack-single measured ({mask:#010x})")
        for r in masked:
            for a in r["args"]:
                if a.get("op") == "SCMP_CMP_MASKED_EQ" and a.get("index") == 0 and a.get("value") not in (mask, 0x7E020000) and a.get("valueTwo", 0) == 0:
                    bad(f"{NODE}: {n} is allowed under a mask of {a.get('value'):#010x}, wider than the one measured")

# ---- C. the installers -----------------------------------------------------------------------
def code_lines(path):
    return [(i + 1, l) for i, l in enumerate(open(path).read().split("\n")) if not l.lstrip().startswith("#")]

installers = []
for path in tracked:
    if path.startswith("scripts/") or not path.endswith(".sh") or not os.path.isfile(path):
        continue
    live = code(open(path).read())
    if re.search(r"sh -s - (serv[e]r|agen[t])", live) and "INSTALL_K3S_VERSION=" in live:
        installers.append(path)
if not installers:
    bad("no tracked script installs k3s, so this measured NOTHING about which nodes get the profile")
for path in installers:
    lines = dict(code_lines(path))
    text = "\n".join(lines.values())
    if not re.search(r'^\. .*/lib/browser-seccomp\.sh"$', text, re.M):
        bad(f"{path}: does not source {LIB}, so its nodes never get the browser's profile")
    installs = [(n, l) for n, l in lines.items()
                if re.search(r'(?:sh_|su_) ("\$FIRST"|"\$n") "(INSTALL_K3S_VERSION=|sh -c \\"IFS= read -r K3S_TOKEN)', l)]
    if not installs:
        bad(f"{path}: no k3s install invocation found, so this cannot tell where the profile has to be written")
    for n, l in sorted(installs):
        node = re.search(r'(?:sh_|su_) ("\$FIRST"|"\$n") ', l).group(1)
        prev = [lines[k] for k in range(max(1, n - 3), n) if k in lines]
        if not any(re.match(r"\s*browser_seccomp_put (sh_|su_) " + re.escape(node) + r" \|\| die ", x) for x in prev):
            bad(f"{path}:{n}: installs k3s on {node} without writing the browser's profile onto it just above, stopping if it cannot")

if os.path.isfile(LIB) and os.path.isfile(NODE):
    with tempfile.TemporaryDirectory() as t:
        probe = f"""
set -u
. ./{LIB}
fake_() {{ printf '%s\\n%s\\n' "$1" "$2" >"{t}/cmd"; cat >"{t}/stdin"; }}
browser_seccomp_put fake_ node-1
"""
        r = subprocess.run(["bash", "-c", probe], capture_output=True, text=True)
        if r.returncode != 0:
            bad(f"browser_seccomp_put failed under a stand-in helper: {r.stderr.strip()}")
        else:
            cmd = open(f"{t}/cmd").read().split("\n")
            target = f"{root}/{name}"
            if cmd[0] != "node-1":
                bad("browser_seccomp_put does not hand the helper the node first")
            if open(f"{t}/stdin", "rb").read() != open(NODE, "rb").read():
                bad(f"browser_seccomp_put does not send {NODE}'s exact bytes to the node")
            body = cmd[1] if len(cmd) > 1 else ""
            if f"cat > {target}.new" not in body or f"mv -f {target}.new {target}" not in body:
                bad(f"browser_seccomp_put does not write {target} through a temporary name moved into place: {body}")

# ---- D. the binding --------------------------------------------------------------------------
if not os.path.isfile(FEATURE):
    bad(f"{FEATURE} is not there, so the behaviour is written nowhere")
else:
    feature = open(FEATURE).read()
    teeth = open("scripts/gates-have-teeth.sh").read()
    bound = set(re.findall(r'# -> gates-have-teeth\.sh "([^"]+)"', feature))
    cases = set(re.findall(r'^run_case "(browser-keeps-its-sandbox: [^"]+)"', teeth, re.M))
    if not bound:
        bad("no scenario is bound to a case")
    for c in sorted(bound - cases):
        bad(f'a scenario names a case that does not exist: "{c}"')
    for c in sorted(cases - bound):
        bad(f'a case no scenario names: "{c}"')
    for chunk in re.split(r"^  Scenario: ", feature, flags=re.M)[1:]:
        if "# -> gates-have-teeth.sh" not in chunk:
            bad(f"a scenario is bound to nothing: {chunk.splitlines()[0]}")

# ---- E. the recorded runs --------------------------------------------------------------------
runs = sorted(p for p in tracked if re.match(r"evidence/browser-sandbox-k3s/output-.*\.txt$", p) and os.path.isfile(p))
if not runs:
    bad("evidence/browser-sandbox-k3s/ holds no recorded run, so nothing says the profile was ever loaded")
arches = set()
for path in runs:
    text = open(path).read()
    tail = [l for l in text.split("\n") if l.strip()][-1:] or [""]
    if tail[0] != "RUN_EXIT=0" or not re.search(r"^\d+ passed, 0 failed$", text, re.M) or re.search(r"^FAIL ", text, re.M):
        bad(f"{path}: the recorded run did not end RUN_EXIT=0 with nothing failed")
    for a, words in (("amd64", ("x86_64",)), ("arm64", ("aarch64",))):
        if any(re.search(r"^arch: " + w + r"$", text, re.M) for w in words):
            arches.add(a)
for a in ("amd64", "arm64"):
    if runs and a not in arches:
        bad(f"no recorded run on {a}, which the browser image is published for and the one profile has to serve")

for p in problems:
    print("FAIL: " + p)
if problems:
    sys.exit(1)
print(f"OK: {len(subjects)} browser manifest(s) under {name}; the profile is stack-single's, resolved; "
      f"{len(installers)} installer(s) write it before every k3s install; {len(runs)} recorded run(s)")
PY
