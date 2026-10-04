#!/usr/bin/env bash
# CLAUDE.md invariant 26: the typed-answer data mode is chosen on purpose, and
# what a mode renders is what it says.
#
# WHY
#
# `--with-typed` used to deploy typryx on the `stub` backend and nothing else.
# Real use needs a choice about where the data goes: Jev (named fields leave to
# TypeSafe's hosted API), the customer's own model on their own hardware, or
# typryx off. That choice is a bill and a data-egress decision, so the default
# stays the free one and the two real modes must be asked for by name.
# `@decided 2026-09-30`: a customer picks one of three data modes for typed
# answers, and the launchers ask which.
#
# typed/mode.sh is the ONE copy of the validation and the rendering. The three
# launchers (deploy.sh, cloud/gcp/deploy-gcp.sh, cloud/aws/deploy-aws.sh) only
# parse flags and hand them to it, for the reason GOTCHAS 90, 101 and 102 give:
# a block copied into three installers drifts.
#
# WHAT THIS CHECKS, by running typed/mode.sh over fake keys and fake URLs:
#
#   1. nothing asked for renders nothing (the default is off);
#   2. --with-typed alone renders manifests/51 and 52 byte for byte (stub);
#   3. jev with no key file, a missing one, an empty one or a blank one refuses,
#      naming the flag, and prints no manifest;
#   4. the jev key is never a literal in any rendered manifest, never an
#      environment value, never in a ConfigMap, never printed by check or
#      render; the env points at a file mounted from a Secret, and the Secret
#      `secrets` emits is the one the Deployment mounts;
#   5. own-model refuses without a URL ending in /v1 and a model name, renders
#      the right environment, and its egress rule follows the URL;
#   6. off renders nothing, and flags that belong to another mode are refused
#      rather than ignored;
#   7. every rendered mode validates against the Kubernetes schema, strictly
#      (kubeconform, as manifests-valid.sh does);
#   8. every launcher parses every flag, refuses BEFORE it installs anything,
#      and renders through typed/mode.sh. Launchers are FOUND by what makes them
#      one (they apply the manifests and parse --with-typed), never listed;
#   9. the training log (--typed-training, typryx's TYPRYX_TRAINING_DIR) is off
#      unless asked for: without the flag no mode renders the variable, and with
#      it the ONLY lines a mode gains are that variable and its comment, so no
#      volume, claim or policy rides in with it;
#  10. with it on, the directory is under a writable mount of a volume the pod
#      already had (the root filesystem is read-only), never under the shared
#      events bus, and no PersistentVolumeClaim exists beyond the one
#      manifests/51 always carried: a claim provisions a billed disk on a cloud
#      cluster, so it is a spending decision the operator makes, not a flag;
#  11. the flag refuses when typryx is not deployed, and every launcher parses
#      it and hands it to typed/mode.sh;
#  12. every typryx image reference in the repository names one tag, and it is
#      v0.4.0 or later: v0.3.0 first read TYPRYX_TRAINING_DIR, and v0.4.0 is the
#      first release that has the `wardryx-proxy` subcommand;
#  13. the typed risk signal (--typed-risk-signal, CLAUDE.md invariant 29) is off
#      unless asked: without the flag no mode renders the proxy, a wardryx setting
#      on the broker, or a widened egress policy;
#  14. with it on, in every mode: one proxy Deployment on the same typryx tag, the
#      SAME backend as typryx (the same environment and the same key mount), no
#      state of its own (no claim, no journal, no ledger, no training log, not
#      the shared bus); the broker, and ONLY the broker, asks wardryx through it
#      (the gateway keeps its direct URL, fail closed, viewer key); the four
#      NetworkPolicy edges broker -> proxy -> wardryx name exactly one peer on
#      one port and nothing selects the proxy for ingress but the broker; the
#      model egress policy selects the proxy too, and no wider; no
#      hold_if_signal policy is seeded anywhere; and every render validates
#      strictly;
#  15. the flag is refused when typryx is not deployed, names itself, and says
#      what it does when accepted; every launcher parses and forwards it.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no typed/mode.sh, no manifests/51, no
# launcher, or no kubeconform is reported and fails.
#
# WHAT IT DOES NOT DO. It runs no cluster. That a pod with a mounted Secret
# starts, and that the egress rule reaches a real model, need a live cluster,
# which invariants 4 and 5 already say this repository cannot hold in a gate.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

python3 - <<'PY'
import base64, os, pathlib, re, shutil, subprocess, sys, tempfile

MODE = pathlib.Path("typed/mode.sh")
M51 = pathlib.Path("manifests/51-typryx.yaml")
M52 = pathlib.Path("manifests/52-tokenfuse-mcp-broker.yaml")

for p in (MODE, M51, M52):
    if not p.exists():
        print(f"FAIL: {p} does not exist, so this measured nothing about the typed data mode.")
        sys.exit(1)

kc = shutil.which("kubeconform")
if not kc:
    gp = subprocess.run(["go", "env", "GOPATH"], capture_output=True, text=True).stdout.strip()
    cand = pathlib.Path(gp) / "bin" / "kubeconform" if gp else None
    kc = str(cand) if cand and cand.exists() else None
if not kc:
    print("FAIL: kubeconform is not on PATH, so the rendered modes were not validated.")
    print("      A schema check that cannot run is not a schema check that passed.")
    sys.exit(1)

errors = []
def check(name, ok, detail=""):
    if not ok:
        errors.append(f"{name}" + (f": {detail}" if detail else ""))

tmp = pathlib.Path(tempfile.mkdtemp())
FAKE = "fake-test-key-not-a-real-key-7f3a9c2e"
FAKE2 = "fake-model-key-not-a-real-key-55d1b0aa"
(tmp / "jev.key").write_text(FAKE + "\n")
(tmp / "empty.key").write_text("")
(tmp / "blank.key").write_text("  \n\n\t\n")
(tmp / "model.key").write_text(FAKE2 + "\n")
(tmp / "adir").mkdir()

def run(verb, *args):
    r = subprocess.run(["bash", str(MODE), verb, *args], capture_output=True, text=True,
                       stdin=subprocess.DEVNULL)
    return r

def b64s(s):
    return [base64.b64encode(s.encode()).decode(), base64.b64encode((s + "\n").encode()).decode()]

JEV = ["--typed-mode", "jev", "--typed-jev-key-file", str(tmp / "jev.key")]
OWN = ["--typed-mode", "own-model", "--typed-model-url", "http://10.1.2.3:11434/v1",
       "--typed-model-name", "qwen2.5:7b"]

# 1. the default renders nothing
for verb in ("check", "render", "secrets"):
    r = run(verb)
    check("1 default is off", r.returncode == 0 and r.stdout == "",
          f"`{verb}` with no flags exited {r.returncode} and printed {len(r.stdout)} bytes")
r = run("mode")
check("1 default is off", r.stdout.strip() == "off", f"`mode` said {r.stdout.strip()!r}, not off")

# 2. --with-typed alone is the stub, byte for byte
r = run("render", "--with-typed")
want = M51.read_text() + "---\n" + M52.read_text()
check("2 --with-typed alone is stub", r.returncode == 0 and r.stdout == want,
      "the render is not manifests/51 and manifests/52 unchanged")
check("2 --with-typed alone is stub", 'name: TYPRYX_BACKEND, value: "stub"' in r.stdout
      and "TYPRYX_JEV" not in re.sub(r"(?m)^\s*#.*$", "", r.stdout)
      and "TYPRYX_OPENAI" not in re.sub(r"(?m)^\s*#.*$", "", r.stdout),
      "stub render carries a jev or openai variable, or lost the stub backend")
check("2 --with-typed alone is stub", run("mode", "--with-typed").stdout.strip() == "stub",
      "`mode --with-typed` did not say stub")
check("2 --with-typed alone is stub", run("secrets", "--with-typed").stdout == "",
      "stub emitted a Secret")

# 3. jev without a usable key file refuses
for label, args in (
    ("no key file flag", ["--typed-mode", "jev"]),
    ("a missing file", ["--typed-mode", "jev", "--typed-jev-key-file", str(tmp / "nope.key")]),
    ("an empty file", ["--typed-mode", "jev", "--typed-jev-key-file", str(tmp / "empty.key")]),
    ("a blank file", ["--typed-mode", "jev", "--typed-jev-key-file", str(tmp / "blank.key")]),
    ("a directory", ["--typed-mode", "jev", "--typed-jev-key-file", str(tmp / "adir")]),
):
    for verb in ("check", "render"):
        r = run(verb, *args)
        check("3 jev without a key file refuses",
              r.returncode != 0 and r.stdout == "" and "--typed-jev-key-file" in r.stderr,
              f"`{verb}` with {label}: exit {r.returncode}, stdout {len(r.stdout)} bytes, "
              f"stderr naming the flag: {'--typed-jev-key-file' in r.stderr}")

# 4. the jev key never becomes a literal
outs = {}
for verb in ("check", "render", "secrets", "mode", "has-secrets"):
    r = run(verb, *JEV)
    outs[verb] = r
    check("4 jev key is a file, never a value", r.returncode == 0,
          f"`{verb}` with a valid key file exited {r.returncode}: {r.stderr.strip()[:160]}")
for verb in ("check", "render", "mode", "has-secrets"):
    blob = outs[verb].stdout + outs[verb].stderr
    leaked = [x for x in [FAKE] + b64s(FAKE) if x in blob]
    check("4 jev key is a file, never a value", not leaked,
          f"`{verb}` output carries the key or its base64")
sec = outs["secrets"].stdout
check("4 jev key is a file, never a value", FAKE not in sec + outs["secrets"].stderr,
      "`secrets` printed the key as a literal")
check("4 jev key is a file, never a value", any(x in sec for x in b64s(FAKE)),
      "`secrets` does not carry the key, base64 encoded")
check("4 jev key is a file, never a value", re.search(r"(?m)^kind: Secret$", sec) is not None
      and outs["has-secrets"].stdout.strip() == "yes", "no Secret emitted for the jev key")
ren = outs["render"].stdout
code = re.sub(r"(?m)^\s*#.*$", "", ren)
check("4 jev key is a file, never a value", 'name: TYPRYX_BACKEND, value: "jev"' in ren,
      "the backend is not jev")
m = re.search(r'name: TYPRYX_JEV_KEY_FILE, value: "([^"]+)"', ren)
check("4 jev key is a file, never a value", m is not None, "TYPRYX_JEV_KEY_FILE is not set to a path")
check("4 jev key is a file, never a value", "kind: ConfigMap" not in code,
      "a ConfigMap is rendered; a key never belongs in one")
for em in re.finditer(r"\{\s*name:\s*(\w*KEY\w*)\s*,\s*value:", code):
    check("4 jev key is a file, never a value",
          em.group(1).endswith("_KEY_FILE") or em.group(1) == "TYPRYX_ACCEPT_KEY_IN_META",
          f"{em.group(1)} is an environment value; a key is a file path, never a value")
mm = re.search(r"secretName:\s*([\w.-]+)", code)
sn = re.search(r"(?m)^  name: ([\w.-]+)$", sec)
check("4 jev key is a file, never a value", mm is not None and sn is not None and mm.group(1) == sn.group(1),
      f"the Deployment mounts Secret {mm.group(1) if mm else None} but `secrets` creates "
      f"{sn.group(1) if sn else None}")
if m:
    dirs = re.findall(r"name:\s*[\w-]*key[\w-]*,\s*mountPath:\s*([^\s,}]+)", code)
    check("4 jev key is a file, never a value", any(m.group(1).startswith(d.rstrip("/") + "/") for d in dirs),
          f"TYPRYX_JEV_KEY_FILE={m.group(1)} is not under a mounted key volume {dirs}")
# the pieces typryx needs are still there
for want in ("typryx-keys", "TYPRYX_EVENTS", "readOnlyRootFilesystem: true", "automountServiceAccountToken: false"):
    check("4 jev key is a file, never a value", want in ren, f"the jev render lost {want}")

# 5. own-model
for label, args in (
    ("no url", ["--typed-mode", "own-model", "--typed-model-name", "m"]),
    ("no model name", ["--typed-mode", "own-model", "--typed-model-url", "http://10.1.2.3:11434/v1"]),
    ("a url that does not end in /v1", ["--typed-mode", "own-model", "--typed-model-url",
                                        "http://10.1.2.3:11434", "--typed-model-name", "m"]),
    ("a url carrying credentials", ["--typed-mode", "own-model", "--typed-model-url",
                                    "http://user:pw@10.1.2.3:11434/v1", "--typed-model-name", "m"]),
    ("a missing model key file", OWN + ["--typed-model-key-file", str(tmp / "nope.key")]),
    ("an empty model key file", OWN + ["--typed-model-key-file", str(tmp / "empty.key")]),
):
    r = run("check", *args)
    check("5 own-model", r.returncode != 0 and r.stderr.strip() != "",
          f"{label} was accepted (exit {r.returncode})")
    check("5 own-model", run("render", *args).stdout == "", f"{label} still rendered a manifest")
r = run("render", *OWN)
code = re.sub(r"(?m)^\s*#.*$", "", r.stdout)
check("5 own-model", r.returncode == 0, f"own-model render exited {r.returncode}: {r.stderr.strip()[:160]}")
for want in ('name: TYPRYX_BACKEND, value: "openai-logprobs"',
             'name: TYPRYX_OPENAI_URL, value: "http://10.1.2.3:11434/v1"',
             'name: TYPRYX_OPENAI_MODEL, value: "qwen2.5:7b"'):
    check("5 own-model", want in r.stdout, f"the render lacks {want}")
check("5 own-model", "TYPRYX_OPENAI_KEY_FILE" not in code and "TYPRYX_JEV" not in code,
      "own-model without a key file still sets a key file, or carries a jev variable")
check("5 own-model", "cidr: 10.1.2.3/32" in code and "port: 11434" in code,
      "a literal IP in the URL does not produce an egress rule for exactly that address and port")
check("5 own-model", run("secrets", *OWN).stdout == "" and run("has-secrets", *OWN).stdout.strip() == "no",
      "own-model with no key file emitted a Secret")
r = run("render", *OWN, "--typed-model-key-file", str(tmp / "model.key"))
code = re.sub(r"(?m)^\s*#.*$", "", r.stdout)
check("5 own-model", 'name: TYPRYX_OPENAI_KEY_FILE, value: "' in code, "the model key file is not wired")
check("5 own-model", not any(x in r.stdout + r.stderr for x in [FAKE2] + b64s(FAKE2)),
      "the model key reached a rendered manifest")
s2 = run("secrets", *OWN, "--typed-model-key-file", str(tmp / "model.key"))
check("5 own-model", any(x in s2.stdout for x in b64s(FAKE2)) and FAKE2 not in s2.stdout,
      "the model key is not in the Secret as base64, or is printed as a literal")
pub = run("render", "--typed-mode", "own-model", "--typed-model-url", "https://models.example.com/v1",
          "--typed-model-name", "m").stdout
check("5 own-model", "0.0.0.0/0" in pub and "10.0.0.0/8" in pub and "port: 443" in pub,
      "a public hostname does not get the public-only egress rule on its port")
svc = run("render", "--typed-mode", "own-model", "--typed-model-url",
          "http://ollama.models.svc.cluster.local:11434/v1", "--typed-model-name", "m").stdout
check("5 own-model", "kubernetes.io/metadata.name: models" in svc and "port: 11434" in svc
      and "0.0.0.0/0" not in re.sub(r"(?m)^\s*#.*$", "", svc),
      "an in-cluster Service URL does not become a namespace-scoped rule")
lan = run("render", "--typed-mode", "own-model", "--typed-model-url", "http://gpu-box.lan:8000/v1",
          "--typed-model-name", "m", "--typed-model-cidr", "192.168.7.0/24").stdout
check("5 own-model", "cidr: 192.168.7.0/24" in lan and "port: 8000" in lan,
      "--typed-model-cidr does not set the egress block")

# 6. off, and flags that belong elsewhere
for verb in ("check", "render", "secrets"):
    r = run(verb, "--typed-mode", "off")
    check("6 off deploys nothing", r.returncode == 0 and r.stdout == "",
          f"`{verb}` with --typed-mode off exited {r.returncode} and printed {len(r.stdout)} bytes")
for label, args in (
    ("off with a key file", ["--typed-mode", "off", "--typed-jev-key-file", str(tmp / "jev.key")]),
    ("off with --with-typed", ["--typed-mode", "off", "--with-typed"]),
    ("an unknown mode", ["--typed-mode", "maybe"]),
    ("a jev key file under own-model", OWN + ["--typed-jev-key-file", str(tmp / "jev.key")]),
    ("a model url under jev", JEV + ["--typed-model-url", "http://10.1.2.3:11434/v1"]),
    ("a key file with no mode", ["--typed-jev-key-file", str(tmp / "jev.key")]),
    ("a key file under --with-typed alone", ["--with-typed", "--typed-jev-key-file", str(tmp / "jev.key")]),
    ("an unknown flag", ["--typed-mode", "off", "--bogus"]),
):
    r = run("check", *args)
    check("6 flags of another mode are refused", r.returncode != 0 and r.stderr.strip() != "",
          f"{label} was accepted (exit {r.returncode})")

# 7. every rendered mode is a schema-valid document, strictly
variants = {
    "stub": ["--with-typed"],
    "jev": JEV,
    "own-model": OWN,
    "own-model with key": OWN + ["--typed-model-key-file", str(tmp / "model.key")],
    "own-model on a service": ["--typed-mode", "own-model", "--typed-model-url",
                               "http://ollama.models.svc/v1", "--typed-model-name", "m"],
    "own-model on a single label": ["--typed-mode", "own-model", "--typed-model-url",
                                    "http://ollama:11434/v1", "--typed-model-name", "m"],
}
rendered = 0
every = dict(variants)
for label, args in variants.items():
    every[label + " + training"] = args + ["--typed-training"]
for label, args in every.items():
    r = run("render", *args)
    f = tmp / ("render-" + re.sub(r"\W+", "-", label) + ".yaml")
    f.write_text(r.stdout)
    body = r.stdout
    if not label.startswith("stub"):
        s = run("secrets", *args).stdout
        body += ("---\n" + s) if s else ""
        f.write_text(body)
    v = subprocess.run([kc, "-strict", "-summary", "-skip", "Secret", str(f)],
                       capture_output=True, text=True)
    # An empty file is a valid document set, so a render that printed nothing
    # would pass kubeconform. Require the Deployment to be there.
    check("7 every rendered mode validates", "kind: Deployment" in r.stdout,
          f"{label}: the render holds no Deployment, so there was nothing to validate")
    check("7 every rendered mode validates", r.returncode == 0 and v.returncode == 0,
          f"{label}: {(v.stdout + v.stderr).strip()[:200] or r.stderr.strip()[:200]}")
    rendered += 1

# 8. launchers, found by what makes them one
FLAGS = ("--typed-mode", "--typed-jev-key-file", "--typed-model-url",
         "--typed-model-name", "--typed-model-key-file", "--typed-model-cidr",
         "--typed-training", "--typed-risk-signal")
tracked = subprocess.run(["git", "ls-files", "*.sh"], capture_output=True, text=True).stdout.split()
# A launcher is a script that applies the manifests to a cluster it is talking to
# (the same subject deploy-flags-agree.sh finds) AND offers --with-typed. typed/mode.sh
# parses --with-typed too, and is the thing being held, not a launcher.
def is_launcher(path):
    text = pathlib.Path(path).read_text()
    return (re.search(r"^\s*--with-typed\)", text, re.M) is not None
            and re.search(r'^[^#]*k_ "apply -k[^"]*manifests"', text, re.M) is not None)
launchers = [p for p in tracked if is_launcher(p)]
if not launchers:
    print("FAIL: no launcher parses --with-typed, so this measured nothing about the launchers.")
    sys.exit(1)
for p in launchers:
    lines = pathlib.Path(p).read_text().splitlines()
    live = [(i + 1, l) for i, l in enumerate(lines) if not l.lstrip().startswith("#")]
    for fl in FLAGS:
        check("8 launchers parse every flag", any(re.match(r"\s*" + re.escape(fl) + r"\)", l) for _, l in live),
              f"{p} does not parse {fl}")
    check("8 launchers never take the key as a value",
          not any(re.match(r"\s*--typed-(jev|model)-key\)", l) for _, l in live),
          f"{p} takes a key VALUE on its command line; a key is a file path, never an argument")
    chk = [n for n, l in live if re.search(r'typed/mode\.sh"?\s+check\b', l)]
    inst = [n for n, l in live if re.match(r'\s*bash\s+.*install(-gcp|-aws)?\.sh"', l)]
    ren = [n for n, l in live if re.search(r'typed/mode\.sh"?\s+render\b', l)]
    check("8 launchers refuse before they install", bool(chk), f"{p} never runs typed/mode.sh check")
    check("8 launchers refuse before they install", bool(inst), f"{p}: cannot find its install step")
    if chk and inst:
        check("8 launchers refuse before they install", min(chk) < min(inst),
              f"{p} checks the typed flags at line {min(chk)}, AFTER the install at line {min(inst)}: "
              "a missing key file would be found after fifteen minutes of building")
    check("8 launchers render through typed/mode.sh", bool(ren), f"{p} never renders through typed/mode.sh")
    direct = [n for n, l in live if re.search(r"apply -f [^|]*manifests/5[126]-", l)]
    check("8 launchers render through typed/mode.sh", not direct,
          f"{p} line {direct[:1]} applies manifests/51 or 52 directly, bypassing the mode")
    check("11 launchers hand --typed-training to typed/mode.sh",
          any(re.search(r"TYPED_ARGS\+=\(--typed-training\)", l) for _, l in live),
          f"{p} parses --typed-training but never adds it to the arguments it gives typed/mode.sh")
    check("15 launchers hand --typed-risk-signal to typed/mode.sh",
          any(re.search(r"TYPED_ARGS\+=\(--typed-risk-signal\)", l) for _, l in live),
          f"{p} parses --typed-risk-signal but never adds it to the arguments it gives typed/mode.sh")

# ---- the training log (typryx v0.3.0, TYPRYX_TRAINING_DIR) ------------------
# Comments and blank lines are not configuration; the checks below read code.
def code_of(text):
    return re.sub(r"(?m)^\s*#.*$", "", text)

def pvcs(text):
    names = []
    for doc in re.split(r"(?m)^---\s*$", text):
        if re.search(r"(?m)^kind: PersistentVolumeClaim\s*$", doc):
            m = re.search(r"(?m)^  name: ([\w.-]+)\s*$", doc)
            names.append(m.group(1) if m else "?")
    return names

# 9. off unless asked, and asking adds an environment variable and nothing else
import difflib
for label, args in variants.items():
    off = run("render", *args).stdout
    on_r = run("render", *args, "--typed-training")
    on = on_r.stdout
    check("9 training is off unless asked", on_r.returncode == 0 and on != "",
          f"{label}: --typed-training did not render (exit {on_r.returncode}): {on_r.stderr.strip()[:160]}")
    check("9 training is off unless asked", "TYPRYX_TRAINING_DIR" not in code_of(off),
          f"{label}: TYPRYX_TRAINING_DIR is rendered WITHOUT --typed-training")
    check("9 training is off unless asked", on.count("TYPRYX_TRAINING_DIR") >= 1
          and re.search(r'\{\s*name:\s*TYPRYX_TRAINING_DIR,\s*value:\s*"[^"]+"\s*\}', code_of(on)) is not None,
          f"{label}: --typed-training does not set TYPRYX_TRAINING_DIR")
    removed, added = [], []
    for d in difflib.ndiff(off.splitlines(), on.splitlines()):
        if d.startswith("- "):
            removed.append(d[2:])
        elif d.startswith("+ "):
            added.append(d[2:])
    check("10 training adds no volume, claim or policy", not removed,
          f"{label}: --typed-training REMOVED lines from the render: {removed[:2]}")
    stray = [l for l in added if l.strip() and not l.lstrip().startswith("#")
             and "TYPRYX_TRAINING_DIR" not in l]
    check("10 training adds no volume, claim or policy", not stray,
          f"{label}: --typed-training added more than the variable: {stray[:2]}")

# 10. where the directory lives
for label, args in variants.items():
    on = run("render", *args, "--typed-training").stdout
    off = run("render", *args).stdout
    code = code_of(on)
    m = re.search(r'name:\s*TYPRYX_TRAINING_DIR,\s*value:\s*"([^"]+)"', code)
    if not m:
        continue  # already reported above
    path = m.group(1)
    mounts = re.findall(r"\{\s*name:\s*([\w-]+),\s*mountPath:\s*([^\s,}]+)([^}]*)\}", code)
    under = [(n, mp, rest) for n, mp, rest in mounts
             if path == mp.rstrip("/") or path.startswith(mp.rstrip("/") + "/")]
    check("10 training has a writable home", bool(under),
          f"{label}: TYPRYX_TRAINING_DIR={path} is under no volumeMount, and the root filesystem is read-only")
    if under:
        n, mp, rest = max(under, key=lambda t: len(t[1]))
        check("10 training has a writable home", "readOnly" not in rest,
              f"{label}: {path} is under {mp}, which is mounted read-only")
        vol = re.search(r"(?m)^        - name: " + re.escape(n) + r"\n(          [^\n]*\n)+", on)
        body = vol.group(0) if vol else ""
        check("10 training has a writable home", vol is not None and
              ("persistentVolumeClaim" in body or "emptyDir" in body),
              f"{label}: the volume {n} behind {path} is neither a claim nor an emptyDir, so it is not writable")
        check("10 training stays off the shared bus", "stack-events" not in body and n != "events",
              f"{label}: the training log would live on the shared events claim, which other planes read")
    check("10 no new disk", pvcs(on) == pvcs(off) == ["typryx-state"],
          f"{label}: claims with the flag {pvcs(on)}, without {pvcs(off)}; only the typryx-state "
          "manifests/51 already carries is allowed. A claim is a billed disk.")
    check("10 no new disk", "volumeClaimTemplates" not in code and "kind: StatefulSet" not in code
          and on.count("emptyDir") == off.count("emptyDir"),
          f"{label}: --typed-training added a volume source")

# 11. it is refused when there is no typryx to write a log, and never silently
for label, args in (
    ("no mode at all", ["--typed-training"]),
    ("--typed-mode off", ["--typed-mode", "off", "--typed-training"]),
):
    r = run("check", *args)
    check("11 training needs typryx", r.returncode != 0 and "--typed-training" in r.stderr,
          f"{label}: accepted (exit {r.returncode}) or did not name the flag")
    check("11 training needs typryx", run("render", *args).stdout == "", f"{label}: still rendered")
for label, args in (("stub", ["--with-typed"]), ("jev", JEV), ("own-model", OWN)):
    r = run("check", *args, "--typed-training")
    check("11 training says what it does", r.returncode == 0 and "training" in r.stderr.lower()
          and "no new disk" in r.stderr.lower(),
          f"{label}: `check --typed-training` exited {r.returncode} and did not say where the log lives")
    check("11 training says what it does", "training" not in run("check", *args).stderr.lower(),
          f"{label}: the notice talks about a training log nobody asked for")
    check("11 training leaves the mode alone",
          run("mode", *args, "--typed-training").stdout == run("mode", *args).stdout
          and run("secrets", *args, "--typed-training").stdout == run("secrets", *args).stdout
          and run("has-secrets", *args, "--typed-training").stdout == run("has-secrets", *args).stdout,
          f"{label}: --typed-training changed the mode, the Secrets or has-secrets")

# ---- the typed risk signal (typryx v0.4.0 wardryx-proxy, wardryx v1.2.0) ----
M56 = pathlib.Path("manifests/56-typryx-wardryx-proxy.yaml")
M10 = pathlib.Path("manifests/10-planes.yaml")
for p in (M56, M10):
    if not p.exists():
        print(f"FAIL: {p} does not exist, so this measured nothing about the typed risk signal.")
        sys.exit(1)


def docs_of(text):
    return [d for d in re.split(r"(?m)^---\s*$", text) if re.search(r"(?m)^kind:\s*\w+", d)]


def kind_name(d):
    k = re.search(r"(?m)^kind:\s*(\w+)", d).group(1)
    n = re.search(r"(?m)^  name:\s*([\w.-]+)", d) or re.search(r"(?m)^metadata:\s*\{\s*name:\s*([\w.-]+)", d)
    return k, (n.group(1) if n else "?")


def env_of(doc):
    """name -> raw text of the entry, for the flow and the block spelling."""
    out = {}
    code = code_of(doc)
    for m in re.finditer(r"\{\s*name:\s*(\w+)\s*,\s*value:\s*\"([^\"]*)\"\s*\}", code):
        out[m.group(1)] = m.group(2)
    for m in re.finditer(r"- name:\s*(\w+)\n\s*valueFrom:\s*(\{[^\n]*\})", code):
        out[m.group(1)] = m.group(2)
    return out


def doc_named(rendered, kind, name):
    hits = [d for d in docs_of(rendered) if kind_name(d) == (kind, name)]
    return hits[0] if len(hits) == 1 else None


RISK = ["--typed-risk-signal"]
# typryx v0.4.0 refuses TYPRYX_PROXY_ASK_TIMEOUT_MS above this (cmd/typryx/wardryxproxy.go).
PROXY_MAX_ASK_MS = 5000

# 13. off unless asked
for label, args in variants.items():
    off = run("render", *args).stdout
    code = code_of(off)
    check("13 risk signal is off unless asked", "typryx-wardryx-proxy" not in code,
          f"{label}: the proxy appears in the render WITHOUT --typed-risk-signal")
    check("13 risk signal is off unless asked", "TOKENFUSE_WARDRYX" not in code,
          f"{label}: the broker carries a wardryx setting WITHOUT --typed-risk-signal")
    check("13 risk signal is off unless asked", "values: [typryx, typryx-wardryx-proxy]" not in code,
          f"{label}: the egress policy selects the proxy WITHOUT --typed-risk-signal")

# Every mode, and the two with the training log ON as well: the log holds question text, and the
# proxy asks about tool-call arguments, so it must never inherit the variable.
base_of = dict(variants)
base_of["stub + training"] = variants["stub"] + ["--typed-training"]
base_of["jev + training"] = variants["jev"] + ["--typed-training"]
risk_variants = {k: v + RISK for k, v in base_of.items()}
rendered_risk = 0
for label, args in risk_variants.items():
    r = run("render", *args)
    out = r.stdout
    check("14 risk signal renders", r.returncode == 0 and out != "",
          f"{label}: exited {r.returncode}: {r.stderr.strip()[:160]}")
    if not out:
        continue
    code = code_of(out)
    proxy = doc_named(out, "Deployment", "typryx-wardryx-proxy")
    typryx = doc_named(out, "Deployment", "typryx")
    broker = doc_named(out, "Deployment", "tokenfuse-mcp-broker")
    check("14 one proxy", proxy is not None, f"{label}: no single Deployment typryx-wardryx-proxy in the render")
    check("14 typryx is still there", typryx is not None and broker is not None,
          f"{label}: the render lost typryx or the broker")
    if proxy is None or typryx is None or broker is None:
        continue
    penv, tenv, benv = env_of(proxy), env_of(typryx), env_of(broker)

    # the same typryx tag as typryx itself, and the subcommand that exists in it
    ptag = re.findall(r"image: ghcr\.io/taipanbox/typryx:(\S+)", proxy)
    ttag = re.findall(r"image: ghcr\.io/taipanbox/typryx:(\S+)", typryx)
    check("14 same typryx tag", len(ptag) == 1 and ptag == ttag,
          f"{label}: the proxy runs typryx {ptag}, typryx runs {ttag}")
    check("14 runs the subcommand", re.search(r'args:\s*\["wardryx-proxy"\]', code_of(proxy)) is not None,
          f"{label}: the proxy container does not run `typryx wardryx-proxy`")

    # the SAME backend as typryx: one answer to where the data goes
    backend_keys = sorted(k for k in set(tenv) | set(penv)
                          if k in ("TYPRYX_BACKEND",) or k.startswith(("TYPRYX_JEV_", "TYPRYX_OPENAI_")))
    check("14 same backend", all(tenv.get(k) == penv.get(k) for k in backend_keys) and backend_keys,
          f"{label}: typryx and the proxy disagree on the backend: "
          + ", ".join(f"{k}: {tenv.get(k)!r} vs {penv.get(k)!r}" for k in backend_keys if tenv.get(k) != penv.get(k)))
    keymounts = lambda doc: sorted(re.findall(r"\{\s*name:\s*([\w-]*key[\w-]*),\s*mountPath:\s*([^\s,}]+)", code_of(doc)))
    check("14 same backend", keymounts(typryx) == keymounts(proxy),
          f"{label}: typryx mounts keys {keymounts(typryx)} but the proxy mounts {keymounts(proxy)}")

    # no state of its own, and never the bus
    for banned in ("TYPRYX_EVENTS", "TYPRYX_LEDGER_DIR", "TYPRYX_TRAINING_DIR"):
        check("14 no state", banned not in penv, f"{label}: the proxy sets {banned}")
    if "training" in label:
        check("14 no state", "TYPRYX_TRAINING_DIR" in tenv,
              f"{label}: --typed-training no longer reaches typryx itself, so the proxy check above proves nothing")
    check("14 no state", "persistentVolumeClaim" not in code_of(proxy) and "stack-events" not in code_of(proxy)
          and "typryx-state" not in code_of(proxy),
          f"{label}: the proxy mounts a claim, the shared bus or typryx's state")
    check("14 no state", pvcs(out) == ["typryx-state"], f"{label}: claims in the render are {pvcs(out)}")
    pc = code_of(proxy)
    check("14 hardened", "automountServiceAccountToken: false" in pc and "readOnlyRootFilesystem: true" in pc
          and 'drop: ["ALL"]' in pc and "allowPrivilegeEscalation: false" in pc and "runAsNonRoot: true" in pc,
          f"{label}: the proxy lost a hardening line")

    # the door is open on purpose, so it must be held by the network and by nothing else
    check("14 the door", penv.get("TYPRYX_ALLOW_OPEN_BIND") == "1" and penv.get("TYPRYX_PROXY_ADDR", "").startswith("0.0.0.0:"),
          f"{label}: the proxy's bind and open-bind setting are not what the NetworkPolicy door assumes")
    check("14 upstream", penv.get("TYPRYX_PROXY_UPSTREAM") == "http://wardryx:8090",
          f"{label}: the proxy's upstream is {penv.get('TYPRYX_PROXY_UPSTREAM')!r}, not wardryx's own Service")

    # ONLY the broker asks wardryx through the proxy
    check("14 broker asks through the proxy", benv.get("TOKENFUSE_WARDRYX_URL") == "http://typryx-wardryx-proxy:4330",
          f"{label}: the broker's TOKENFUSE_WARDRYX_URL is {benv.get('TOKENFUSE_WARDRYX_URL')!r}")
    check("14 broker asks through the proxy", benv.get("TOKENFUSE_WARDRYX_MODE") == "enforce"
          and benv.get("TOKENFUSE_WARDRYX_FAILMODE") == "closed",
          f"{label}: the broker's wardryx mode or fail mode is not enforce/closed")
    check("14 broker asks through the proxy", "key: wardryx_gateway" in benv.get("TOKENFUSE_WARDRYX_KEY", ""),
          f"{label}: the broker does not use the viewer key wardryx_gateway: {benv.get('TOKENFUSE_WARDRYX_KEY')!r}")
    try:
        mcp_ms, ask_ms = int(benv["TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS"]), int(penv["TYPRYX_PROXY_ASK_TIMEOUT_MS"])
        check("14 deadlines nest", mcp_ms > max(ask_ms, PROXY_MAX_ASK_MS),
              f"{label}: the broker waits {mcp_ms} ms for a proxy that may take {ask_ms} ms to ask typryx "
              f"(and up to {PROXY_MAX_ASK_MS} ms if raised): the wait must exceed the longest ask")
        check("14 deadlines fit the backends", ask_ms >= 3000,
              f"{label}: the proxy's ask deadline is {ask_ms} ms; an own model on CPU measured p50 2,130 ms "
              "(typryx-evalset bench), so below 3000 ms most own-model answers are dropped")
    except (KeyError, ValueError):
        check("14 deadlines nest", False, f"{label}: the broker's or the proxy's deadline is not set")
    check("14 broker only", sum(1 for v in [env_of(d).get("TOKENFUSE_WARDRYX_URL") for d in docs_of(out)]
                                if v and "typryx-wardryx-proxy" in v) == 1,
          f"{label}: more than one workload points its wardryx URL at the proxy")

    # the NetworkPolicy edges
    def policy(name):
        return doc_named(out, "NetworkPolicy", name)
    edges = (
        ("broker-egress-typryx-proxy", "tokenfuse-mcp-broker", "Egress", "typryx-wardryx-proxy", "4330"),
        ("typryx-proxy-ingress-broker", "typryx-wardryx-proxy", "Ingress", "tokenfuse-mcp-broker", "4330"),
        ("typryx-proxy-egress-wardryx", "typryx-wardryx-proxy", "Egress", "wardryx", "8090"),
        ("wardryx-ingress-typryx-proxy", "wardryx", "Ingress", "typryx-wardryx-proxy", "8090"),
    )
    for name, selects, direction, peer, port in edges:
        d = policy(name)
        if d is None:
            check("14 edges", False, f"{label}: no NetworkPolicy {name}")
            continue
        dc = code_of(d)
        check("14 edges", f"podSelector: {{ matchLabels: {{ app: {selects} }} }}" in dc
              and f'policyTypes: ["{direction}"]' in dc
              and len(re.findall(r"podSelector:", dc)) == 2
              and f"podSelector: {{ matchLabels: {{ app: {peer} }} }}" in dc
              and re.findall(r"port:\s*(\d+)", dc) == [port],
              f"{label}: {name} is not exactly {selects} {direction} {peer}:{port}")
        check("14 edges", "podSelector: {}" not in dc and "namespaceSelector" not in dc and "ipBlock" not in dc,
              f"{label}: {name} admits or reaches more than the one named peer")
    # nothing else may let anything into the proxy
    ingress_to_proxy = [kind_name(d)[1] for d in docs_of(out)
                        if kind_name(d)[0] == "NetworkPolicy" and "app: typryx-wardryx-proxy" in code_of(d).split("ingress:")[0]
                        and "Ingress" in code_of(d)]
    check("14 the door", ingress_to_proxy == ["typryx-proxy-ingress-broker"],
          f"{label}: ingress policies selecting the proxy: {ingress_to_proxy}; the one door is typryx-proxy-ingress-broker")

    # the model egress follows the mode and selects both pods, no wider
    egress = doc_named(out, "NetworkPolicy", "typryx-egress-model")
    if label.startswith("stub"):
        check("14 model egress", egress is None, f"{label}: the stub rendered a model egress policy")
    else:
        check("14 model egress", egress is not None and "values: [typryx, typryx-wardryx-proxy]" in egress,
              f"{label}: typryx-egress-model does not select the proxy, which answers from the same backend")
        base_egress = doc_named(run("render", *base_of[label]).stdout, "NetworkPolicy", "typryx-egress-model")
        norm = lambda d: re.sub(r"podSelector:[^\n]*\n", "", code_of(d)) if d else None
        check("14 model egress", base_egress is not None and norm(egress) == norm(base_egress),
              f"{label}: the proxy's way out is not exactly typryx's: the peers or ports differ")

    # nothing seeded
    check("14 nothing is held by default", "hold_if_signal" not in code,
          f"{label}: the render seeds a hold_if_signal policy; none is shipped, the operator writes it")

    # strict schema
    f = tmp / ("risk-" + re.sub(r"\W+", "-", label) + ".yaml")
    body = out
    sec = run("secrets", *args).stdout
    body += ("---\n" + sec) if sec else ""
    f.write_text(body)
    v = subprocess.run([kc, "-strict", "-summary", "-skip", "Secret", str(f)], capture_output=True, text=True)
    check("14 every risk render validates", v.returncode == 0, f"{label}: {(v.stdout + v.stderr).strip()[:200]}")
    rendered_risk += 1

    # the key is still never a literal, with the proxy carrying it too
    if label == "jev":
        check("14 jev key is a file in the proxy too", FAKE not in out and not any(x in out for x in b64s(FAKE)),
              "the jev key reached the render through the proxy")

# nothing in the repository seeds a hold_if_signal policy
for path in subprocess.run(["git", "ls-files", "manifests"], capture_output=True, text=True).stdout.split():
    try:
        text = pathlib.Path(path).read_text()
    except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
        continue
    check("14 nothing is held by default", "hold_if_signal" not in code_of(text),
          f"{path} seeds a hold_if_signal policy; none is shipped, the operator writes it (README)")

# the LLM gateway keeps asking wardryx directly, whatever the flag
gw = [d for d in docs_of(M10.read_text()) if kind_name(d) == ("Deployment", "tokenfuse-gateway")]
check("14 the gateway is untouched", len(gw) == 1 and env_of(gw[0]).get("TOKENFUSE_WARDRYX_URL") == "http://wardryx:8090"
      and env_of(gw[0]).get("TOKENFUSE_WARDRYX_FAILMODE") == "closed",
      "the gateway no longer asks wardryx directly, or no longer fails closed: the typed answer must never sit on the model path")

# 15. refused with no typryx, named, and says what it does
for label, args in (("no mode at all", RISK), ("--typed-mode off", ["--typed-mode", "off"] + RISK)):
    r = run("check", *args)
    check("15 risk signal needs typryx", r.returncode != 0 and "--typed-risk-signal" in r.stderr,
          f"{label}: accepted (exit {r.returncode}) or did not name the flag")
    for verb in ("render", "secrets"):
        check("15 risk signal needs typryx", run(verb, *args).stdout == "", f"{label}: `{verb}` still printed a manifest")
for label, args in (("stub", ["--with-typed"]), ("jev", JEV), ("own-model", OWN)):
    r = run("check", *args, *RISK)
    err = r.stderr.lower()
    check("15 risk signal says what it does", r.returncode == 0 and "every tool call" in err and "fails closed" in err
          and "no policy is seeded" in err,
          f"{label}: `check --typed-risk-signal` exited {r.returncode} and did not say that the broker now asks about "
          "every tool call, fails closed, and that no policy is seeded")
    check("15 risk signal says what it does", "risk signal" not in run("check", *args).stderr.lower(),
          f"{label}: the notice talks about a risk signal nobody asked for")
    check("15 risk signal leaves the mode alone",
          run("mode", *args, *RISK).stdout == run("mode", *args).stdout
          and run("secrets", *args, *RISK).stdout == run("secrets", *args).stdout
          and run("has-secrets", *args, *RISK).stdout == run("has-secrets", *args).stdout,
          f"{label}: --typed-risk-signal changed the mode, the Secrets or has-secrets")

# 12. one typryx tag everywhere, and it is one that has the wardryx-proxy subcommand
MIN_TYPRYX = (0, 4, 0)
refs = []
for path in subprocess.run(["git", "ls-files"], capture_output=True, text=True).stdout.split():
    # GOTCHAS.md is the dated ledger: entry 106 names v0.1.0 because that is what was
    # pinned when the trap was met, and history is not reworded in place.
    # The two scripts that hold this rule carry stale tags as text on purpose (the
    # harness plants one to prove this check fails on it), so they are not pins.
    if path in ("GOTCHAS.md", "scripts/gates-have-teeth.sh", "scripts/typed-mode-is-honest.sh"):
        continue
    try:
        text = pathlib.Path(path).read_text()
    except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
        continue
    for lineno, line in enumerate(text.splitlines(), 1):
        # Only a TAGGED reference is a pin; a bare image name in prose is not.
        for mm in re.finditer(r"ghcr\.io/taipanbox/typryx:([^\s\"'`,)]+)", line):
            refs.append((path, lineno, mm.group(1)))
if not refs:
    print("FAIL: no reference to ghcr.io/taipanbox/typryx in any tracked file, so this measured nothing "
          "about the typryx pin.")
    sys.exit(1)
tags = sorted({t for _, _, t in refs})
check("12 one typryx tag", len(tags) == 1,
      f"typryx is referenced at {len(tags)} different tags {tags}: "
      + ", ".join(f"{p}:{n}={t}" for p, n, t in refs[:6]))
for t in tags:
    mv = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", t or "")
    check("12 typryx has the wardryx-proxy subcommand",
          mv is not None and tuple(int(x) for x in mv.groups()) >= MIN_TYPRYX,
          f"typryx tag {t!r} is older than v{'.'.join(map(str, MIN_TYPRYX))}, which is where the "
          "`wardryx-proxy` subcommand starts to exist (and v0.3.0 is where TYPRYX_TRAINING_DIR does); "
          "an older image refuses the subcommand, or ignores the variable and writes nothing")
for label, args in every.items():
    img = re.findall(r"image: (ghcr\.io/taipanbox/typryx:\S+)", run("render", *args).stdout)
    check("12 one typryx tag", len(img) == 1 and (not tags or img[0].endswith(":" + tags[0])),
          f"{label}: the render's typryx image is {img}")
for label, args in risk_variants.items():
    img = re.findall(r"image: (ghcr\.io/taipanbox/typryx:\S+)", run("render", *args).stdout)
    check("12 one typryx tag", len(img) == 2 and len(set(img)) == 1 and (not tags or img[0].endswith(":" + tags[0])),
          f"{label}: typryx and its proxy should both run the one pinned tag, the render names {img}")

shutil.rmtree(tmp, ignore_errors=True)
if errors:
    for e in errors:
        print(f"FAIL: {e}")
    print()
    print(f"{len(errors)} way(s) the typed data mode is not honest. See CLAUDE.md invariant 26.")
    sys.exit(1)
print(f"OK: typed/mode.sh renders nothing by default, the stub for --with-typed alone, refuses a jev "
      f"key file that is missing or empty, never renders a key as a literal, and {rendered} modes "
      f"(each with and without the training log) validate strictly; the training log adds one variable "
      f"and no disk; the risk signal is off unless asked and, on, adds one stateless proxy with typryx's own "
      f"backend ({rendered_risk} render(s) validate); {len(launchers)} launcher(s) parse every flag and refuse before installing; "
      f"{len(refs)} typryx image reference(s) agree on {tags[0]}.")
PY
