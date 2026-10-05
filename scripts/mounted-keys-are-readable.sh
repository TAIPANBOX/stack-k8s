#!/usr/bin/env bash
# CLAUDE.md invariant 32: every file a pod mounts from a Secret, a ConfigMap or a
# projected volume is readable by the user the pod runs as.
#
# WHY
#
# Kubernetes writes those files owned by root. The group is the pod's `fsGroup`
# when it has one and root's otherwise; the mode is `defaultMode` (or an item's
# `mode`), 0644 when nothing sets it. So a key mounted at 0440, the mode
# typed/mode.sh gives the Jev key and an own model's key, is readable by a
# non-root container only through `fsGroup`: without it the file is
# root:root 0440 and the read is `permission denied`.
#
# That is not a hypothesis. Measured on k3d on forge, 2026-10-05, stack-k8s
# 0dd0011: `typed/mode.sh render --typed-mode jev --typed-jev-key-file <file>
# --typed-risk-signal`, applied as deploy.sh applies it, left
# `typryx-wardryx-proxy` in CrashLoopBackOff with `TYPRYX_JEV_KEY_FILE=
# /etc/typryx/jev/key could not be read: open /etc/typryx/jev/key: permission
# denied`. typryx itself, same Secret, same mode, read it: its pod carries
# `fsGroup: 10001` for the shared bus, so it had the right group by accident,
# and the proxy, which mounts no claim, had none. GOTCHAS 117.
#
# Every other gate here reads the env, the image, the policies and the schema;
# kubeconform accepts the pod, typed-mode-is-honest.sh checks the proxy mounts
# the SAME key as typryx, and nothing asked whether the user could open it.
#
# WHAT THIS CHECKS
#
# Subjects, found rather than listed: every pod template in manifests/*.yaml
# (Deployment, StatefulSet, DaemonSet, Job, CronJob, Pod, and the kind-less
# `kubectl patch --patch-file` bodies), and every pod template typed/mode.sh renders across its
# modes (stub, jev, own-model with and without a key), each with and without
# --typed-risk-signal and --typed-training. For each Secret, ConfigMap or
# projected volume, every mode it sets (the default, and each item's) must be
# readable by the pod's user:
#
#   - world-readable (o+r), or
#   - group-readable (g+r) and the pod has a group the file will carry: an
#     `fsGroup`, or gid 0 as its runAsGroup or a supplemental group, or
#   - the pod runs as uid 0 (none here does; runAsNonRoot is everywhere).
#
# The owner bit alone never helps a non-root pod: the owner is root.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no manifests/*.yaml, no pod template
# found in them, no typed/mode.sh, or no key Secret mounted in any typed render
# is reported and fails. A mode it cannot read as a number fails too.
#
# WHAT IT DOES NOT DO. It reads the pod-level securityContext only: a container
# that overrides runAsUser or runAsGroup is judged by the pod's values. It
# judges every volume a pod declares, mounted or not. It cannot see an image
# whose own user differs from what the manifest states. That the file opens on
# a running cluster is a live run (GOTCHAS 117 has the one that was made).
# A patch body is judged on its own securityContext, not its target's, because
# the target is named by the script that applies it: so a patch that mounts a
# restricted mode fails here unless it carries an fsGroup itself, even when its
# target has one. Stricter than the platform, on purpose; both patches today
# mount at the default 0644.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

python3 - <<'PY'
import pathlib, re, subprocess, sys, tempfile

POD_KINDS = {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "CronJob", "Pod"}
MODE = pathlib.Path("typed/mode.sh")

errors = []


def indent(line):
    return len(line) - len(line.lstrip(" "))


def live(line):
    s = line.strip()
    return s != "" and not s.startswith("#")


def strip_comment(line):
    # Good enough for these manifests: no value here carries " #".
    return re.sub(r"\s+#.*$", "", line)


def block_after(lines, i, base):
    """Lines after lines[i] that belong to the key at indent `base`: deeper than it,
    or list items at the same indent (YAML lets a sequence sit level with its key)."""
    out = []
    for line in lines[i + 1:]:
        if not live(line):
            continue
        ind = indent(line)
        if ind > base or (ind == base and line.lstrip().startswith("- ")):
            out.append(strip_comment(line))
        else:
            break
    return out


def parse_mode(tok):
    tok = tok.strip()
    if re.fullmatch(r"0o[0-7]+", tok):
        return int(tok[2:], 8)
    if re.fullmatch(r"0[0-7]+", tok):
        return int(tok, 8)  # YAML 1.1, which is what Kubernetes reads: 0440 is octal
    if re.fullmatch(r"[0-9]+", tok):
        return int(tok)
    return None


def docs(text):
    return re.split(r"(?m)^---\s*$", text)


def kind_name(doc):
    k = re.search(r"(?m)^kind:\s*(\w+)", doc)
    n = re.search(r"(?m)^  name:\s*([\w.-]+)", doc) or re.search(r"(?m)^metadata:\s*\{\s*name:\s*([\w.-]+)", doc)
    return (k.group(1) if k else None), (n.group(1) if n else "?")


def judge(subject, text, counts):
    """Judge every pod template in `text`. Returns the number of key-Secret volumes seen."""
    keys_seen = 0
    for doc in docs(text):
        kind, name = kind_name(doc)
        if kind is None and re.search(r"(?m)^spec:\s*$", doc) and re.search(r"(?m)^\s+containers:", doc):
            # A `kubectl patch --patch-file` body: no kind, merged into a Deployment named
            # elsewhere. Judged on what it carries itself, so a restricted mode in a patch
            # passes only if the patch also brings an fsGroup (see the header).
            kind, name = "patch", subject
        elif kind not in POD_KINDS:
            continue
        lines = doc.splitlines()
        # The pod spec is the mapping that holds `containers:`; its indent is P.
        cidx = [i for i, l in enumerate(lines) if re.match(r"^\s*containers:", l) and live(l)]
        if not cidx:
            continue  # a patch fragment that touches no container list
        if len(cidx) != 1:
            errors.append(f"{subject}: {kind}/{name} has {len(cidx)} `containers:` keys; cannot tell which is the pod's")
            continue
        P = indent(lines[cidx[0]])
        counts["pods"] += 1

        sc_text = ""
        for i, l in enumerate(lines):
            if live(l) and indent(l) == P and re.match(r"^\s*securityContext:", l):
                rest = strip_comment(l).split("securityContext:", 1)[1].strip()
                sc_text = rest if rest else "\n".join(block_after(lines, i, P))
        def num(field):
            m = re.search(r"\b" + field + r":\s*(\d+)", sc_text)
            return int(m.group(1)) if m else None
        fs_group, run_as_user, run_as_group = num("fsGroup"), num("runAsUser"), num("runAsGroup")
        sup = re.search(r"supplementalGroups:\s*\[([^\]]*)\]", sc_text)
        sup_groups = {int(x) for x in re.findall(r"\d+", sup.group(1))} if sup else set()
        if run_as_user == 0:
            continue  # root reads anything; nothing here runs as root

        vidx = [i for i, l in enumerate(lines) if live(l) and indent(l) == P and re.match(r"^\s*volumes:", l)]
        if not vidx:
            continue
        block = block_after(lines, vidx[0], P)
        if not block:
            continue
        item_ind = indent(block[0])
        items, cur = [], []
        for l in block:
            if indent(l) == item_ind and l.lstrip().startswith("- "):
                if cur:
                    items.append(cur)
                cur = [l]
            else:
                cur.append(l)
        if cur:
            items.append(cur)

        for it in items:
            body = "\n".join(it)
            src = re.search(r"\b(secret|configMap|projected):", body)
            if not src:
                continue
            vname = re.search(r"name:\s*([\w.-]+)", body)
            vname = vname.group(1) if vname else "?"
            counts["volumes"] += 1
            if re.search(r"\bsecret:", body) or re.search(r"secretName:", body):
                keys_seen += 1
            dm = re.search(r"\bdefaultMode:\s*([^\s,}]+)", body)
            modes = [("defaultMode", dm.group(1) if dm else "0644")]
            modes += [("an item's mode", m) for m in re.findall(r"\bmode:\s*([^\s,}]+)", body)]
            for where, tok in modes:
                mode = parse_mode(tok)
                if mode is None:
                    errors.append(f"{subject}: {kind}/{name} volume {vname}: {where} {tok!r} is not a number this gate can read")
                    continue
                counts["modes"] += 1
                group_ok = bool(mode & 0o040) and (fs_group is not None or run_as_group == 0 or 0 in sup_groups)
                if mode & 0o004 or group_ok:
                    continue
                who = f"uid {run_as_user if run_as_user is not None else '(the image user)'}"
                group = f"root:{fs_group}" if fs_group is not None else "root:root"
                why = ("no fsGroup, so the file stays root:root" if fs_group is None
                       else f"fsGroup {fs_group} gives the group, but the mode has no group read")
                errors.append(f"{subject}: {kind}/{name} mounts {src.group(1)} volume {vname} at {where} {oct(mode)[2:].zfill(4)}, "
                              f"owned {group}; {why}, and {who} cannot open it (permission denied at start)")
    return keys_seen


counts = {"pods": 0, "volumes": 0, "modes": 0}

# 1. every manifest, as written
manifests = sorted(pathlib.Path("manifests").glob("*.yaml"))
if not manifests:
    print("FAIL: no manifests/*.yaml, so this measured nothing about mounted files.")
    sys.exit(1)
for p in manifests:
    judge(str(p), p.read_text(), counts)
if counts["pods"] == 0:
    print("FAIL: no pod template found in manifests/*.yaml, so this measured nothing about mounted files.")
    sys.exit(1)
static_pods = counts["pods"]

# 2. every typed render
if not MODE.exists():
    print(f"FAIL: {MODE} does not exist, so this measured nothing about the typed key mounts.")
    sys.exit(1)
tmp = pathlib.Path(tempfile.mkdtemp())
(tmp / "jev.key").write_text("fake-test-key-not-a-real-key\n")
(tmp / "model.key").write_text("fake-model-key-not-a-real-key\n")
OWN = ["--typed-mode", "own-model", "--typed-model-url", "http://10.1.2.3:11434/v1", "--typed-model-name", "m"]
modes = {
    "stub": ["--with-typed"],
    "jev": ["--typed-mode", "jev", "--typed-jev-key-file", str(tmp / "jev.key")],
    "own-model": OWN,
    "own-model with key": OWN + ["--typed-model-key-file", str(tmp / "model.key")],
}
renders, keys_in_renders = 0, 0
for label, args in modes.items():
    for extra in ([], ["--typed-risk-signal"], ["--typed-training"], ["--typed-risk-signal", "--typed-training"]):
        r = subprocess.run(["bash", str(MODE), "render", *args, *extra], capture_output=True, text=True,
                           stdin=subprocess.DEVNULL)
        sub = "typed/mode.sh render " + label + ("" if not extra else " " + " ".join(extra))
        if r.returncode != 0 or "kind: Deployment" not in r.stdout:
            errors.append(f"{sub}: rendered nothing to judge (exit {r.returncode}): {r.stderr.strip()[:160]}")
            continue
        keys_in_renders += judge(sub, r.stdout, counts)
        renders += 1
if keys_in_renders == 0:
    print("FAIL: no typed render mounts a Secret, so this measured nothing about the key files.")
    sys.exit(1)

if errors:
    for e in errors:
        print(f"FAIL: {e}")
    print()
    print(f"{len(errors)} mounted file(s) the pod cannot read. See CLAUDE.md invariant 32 and GOTCHAS 117.")
    sys.exit(1)
print(f"OK: {counts['pods']} pod template(s) ({static_pods} in manifests/, the rest in {renders} typed renders), "
      f"{counts['volumes']} Secret/ConfigMap/projected volume(s), {counts['modes']} mode(s), "
      f"{keys_in_renders} key Secret mount(s) in the renders: every mounted file is readable by its pod's user.")
PY
