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
#      one (they apply the manifests and parse --with-typed), never listed.
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
for label, args in variants.items():
    r = run("render", *args)
    f = tmp / ("render-" + re.sub(r"\W+", "-", label) + ".yaml")
    f.write_text(r.stdout)
    body = r.stdout
    if label != "stub":
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
         "--typed-model-name", "--typed-model-key-file", "--typed-model-cidr")
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
    direct = [n for n, l in live if re.search(r"apply -f [^|]*manifests/5[12]-", l)]
    check("8 launchers render through typed/mode.sh", not direct,
          f"{p} line {direct[:1]} applies manifests/51 or 52 directly, bypassing the mode")

shutil.rmtree(tmp, ignore_errors=True)
if errors:
    for e in errors:
        print(f"FAIL: {e}")
    print()
    print(f"{len(errors)} way(s) the typed data mode is not honest. See CLAUDE.md invariant 26.")
    sys.exit(1)
print(f"OK: typed/mode.sh renders nothing by default, the stub for --with-typed alone, refuses a jev "
      f"key file that is missing or empty, never renders a key as a literal, and {rendered} modes "
      f"validate strictly; {len(launchers)} launcher(s) parse every flag and refuse before installing.")
PY
