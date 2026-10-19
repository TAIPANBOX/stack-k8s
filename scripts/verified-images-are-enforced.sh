#!/usr/bin/env bash
# Enforces invariant 58 of CLAUDE.md: the admission policy admits an image only when a signature
# verifies that its OWN repository's workflow made, every image the stack names is pinned by digest,
# and the one thing the policy trusts without a signature is listed, with a reason, next to the
# digest it trusts. The default install turns the policy on for the stack's namespace.
#
# WHY
#
# A launcher that pins by tag and pulls whatever the registry serves today runs a different image
# after every re-push of that tag, and nothing on the cluster says so. Every TAIPANBOX release is
# signed keyless by its own release workflow, but no launcher checks that before it runs an image.
# The Sigstore policy-controller checks it, given a ClusterImagePolicy that names the expected signer.
#
# The first version named ONE identity for every TAIPANBOX image: the release workflow of any
# TAIPANBOX repository. A signature made by one repository's workflow then admitted another
# repository's image name. So there is one policy per repository, and each names only that
# repository's workflow (or stack-k8s's console-image.yml or tunnel-images.yml).
#
# WHAT THIS CHECKS
#
#   1. policy/PIN records the controller release, its source commit, the one image it runs by digest,
#      and the sha256 of the rendered manifest; the manifest on disk is that file, byte for byte.
#   2. Every ClusterImagePolicy whose glob is under ghcr.io/taipanbox/: enforce mode, GitHub Actions
#      issuer, one keyless authority with one identity, digest-anchored globs of one image name each,
#      and a subject expression equal to the expected one for that image's repository and workflow. Its
#      own release on a version tag must match it; every OTHER binding's identity must not.
#   3. Every image name the tracked manifests and scripts reference under ghcr.io/taipanbox/ has a row
#      in BINDINGS, and exactly one policy covers it. A name with no row, or with no policy, is refused
#      by the controller (no-match-policy: deny) and is a finding here, not a silent gap.
#   4. Every static (unsigned) allow is pinned by digest and carries a reason, and the digests in the
#      manifests are the digests the static allows name.
#   5. policy/up.sh installs the controller, waits for its webhook, applies the policies and only then
#      opts the stack's namespace in.
#   6. Every image reference in a tracked YAML or shell file is pinned by digest. A TAIPANBOX image is
#      covered by check 3; an upstream image must be one of the static allows; the rest of the
#      exceptions are listed below with reasons.
#   7. The default apply set (manifests/kustomization.yaml) does not name policy/, and deploy.sh turns
#      admission on for the stack's namespace after its apply (the default install).
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import hashlib
import os
import re
import subprocess
import sys

NOTHING = "verified-images-are-enforced: {} is absent, so this gate measured NOTHING"

for needed in ("policy/PIN", "policy/policy-controller.yaml", "policy/image-policy.yaml", "policy/up.sh", "deploy.sh"):
    if not os.path.exists(needed):
        print(NOTHING.format(needed))
        sys.exit(1)

bad = []


def read(p):
    with open(p) as f:
        return f.read()


def live_lines(text):
    """Lines that are not comments, with their line numbers."""
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        yield n, line


def value(text, key):
    m = re.search(rf"^{key}:\s*(\S+)\s*$", text, re.M)
    return m.group(1) if m else None


# The image name -> (repository, workflow file) that signs it. A row here is a decision: which
# repository's release is the signer of that image. Every TAIPANBOX image the tracked files name must
# have a row (check 3), so a new image cannot ride into the policy without its signer being written down.
BINDINGS = {
    "tokenfuse": ("tokenfuse", "release.yml"),
    "tokenfuse-control-plane": ("tokenfuse", "release.yml"),
    "wardryx": ("wardryx", "release.yml"),
    "idryx": ("idryx", "release.yml"),
    "heraldyx": ("heraldyx", "release.yml"),
    "vouchryx": ("vouchryx", "release.yml"),
    "scopyx": ("scopyx", "release.yml"),
    "typryx": ("typryx", "release.yml"),
    "costcrew": ("costcrew", "release.yml"),
    "qryx": ("qryx", "release.yml"),
    "trailryx-node": ("trailryx", "release.yml"),
    "mockryx": ("mockryx", "release.yml"),
    "keyryx": ("keyryx", "release.yml"),
    "agent-conform": ("agent-stack-go", "release.yml"),
    "genaryx-console": ("stack-k8s", "console-image.yml"),
    "stack-caddy": ("stack-k8s", "tunnel-images.yml"),
    "stack-wg": ("stack-k8s", "tunnel-images.yml"),
}
REPO_RE = re.compile(r"^[A-Za-z0-9-]+$")
for img, (repo, wf) in BINDINGS.items():
    assert REPO_RE.match(repo) and wf.endswith(".yml"), (img, repo, wf)

ISSUER = "https://token.actions.githubusercontent.com"


def subject_for(repo, wf):
    # the repository and workflow names are plain (no regex metacharacters but the dot in the file name)
    return ("^https://github\\.com/TAIPANBOX/" + repo + "/\\.github/workflows/"
            + wf.replace(".", "\\.") + "@refs/tags/v[0-9][A-Za-z0-9._+-]*$")


def identity_of(repo, wf, tag):
    return f"https://github.com/TAIPANBOX/{repo}/.github/workflows/{wf}@refs/tags/{tag}"


# 1. The controller is the one recorded in policy/PIN, byte for byte.
pin = read("policy/PIN")
controller = read("policy/policy-controller.yaml")
want_sha = value(pin, "rendered_sha256")
want_image = value(pin, "image")
if not want_sha or not want_image:
    bad.append("policy/PIN does not record rendered_sha256 and image")
got_sha = hashlib.sha256(controller.encode()).hexdigest()
if want_sha and got_sha != want_sha:
    bad.append(f"policy/policy-controller.yaml is not the rendered release pinned in policy/PIN "
               f"(sha256 {got_sha}, PIN says {want_sha}); bump both together or not at all")
images_in_controller = [line.split("image:", 1)[1].strip() for _, line in live_lines(controller)
                        if re.match(r"^\s*image:", line)]
if not images_in_controller:
    bad.append("policy/policy-controller.yaml names no image, so the controller is measured NOTHING")
for img in images_in_controller:
    if "ko://" in img:
        bad.append(f"the controller names an unrendered ko:// image: {img}")
    elif "@sha256:" not in img:
        bad.append(f"the controller image is not pinned by digest: {img}")
    elif want_image and img != want_image:
        bad.append(f"the controller runs {img}, but policy/PIN records {want_image}")

# 2. The policies. Documents are split on the YAML separator; a ClusterImagePolicy is a document with that kind.
ip = read("policy/image-policy.yaml")
docs = [d for d in re.split(r"\n---\s*\n", ip) if re.search(r"^kind:\s*ClusterImagePolicy\s*$", d, re.M)]
taipanbox_policies = {}   # policy name -> doc
static_docs = []
for d in docs:
    m = re.search(r"^  name:\s*(\S+)\s*$", d, re.M)
    pname = m.group(1) if m else "(unnamed)"
    if re.search(r"glob:\s*['\"]?ghcr\.io/taipanbox/", d):
        taipanbox_policies[pname] = d
    else:
        static_docs.append(d)

if not taipanbox_policies:
    bad.append("policy/image-policy.yaml has no ClusterImagePolicy under ghcr.io/taipanbox/, so this gate measured NOTHING about the signers")

GLOB_RE = re.compile(r"^ghcr\.io/taipanbox/([a-z0-9-]+)@sha256:\*$")
cover = {}   # image name -> policy name
for pname, d in taipanbox_policies.items():
    if not re.search(r"^\s*mode:\s*enforce\s*$", d, re.M):
        bad.append(f"{pname}: mode is not enforce (a warn policy admits the unsigned image)")
    if not re.search(rf"issuer:\s*['\"]?{re.escape(ISSUER)}['\"]?\s*$", d, re.M):
        bad.append(f"{pname}: issuer is not {ISSUER}")
    globs = re.findall(r"^\s*-\s*glob:\s*['\"]?([^'\"\s]+)['\"]?\s*$", d, re.M)
    if not globs:
        bad.append(f"{pname}: names no glob, so it covers no image")
    names = []
    for g in globs:
        m = GLOB_RE.match(g)
        if not m:
            bad.append(f"{pname}: glob {g} is not a digest-anchored name of one repository "
                       "(ghcr.io/taipanbox/<name>@sha256:*); a wider glob would cover another repository's images")
            continue
        names.append(m.group(1))
        if m.group(1) in cover:
            bad.append(f"ghcr.io/taipanbox/{m.group(1)} is covered by two policies ({cover[m.group(1)]} and {pname})")
        cover[m.group(1)] = pname
    subjects = re.findall(r"subjectRegExp:\s*['\"]?(.+?)['\"]?\s*$", d, re.M)
    if len(subjects) != 1:
        bad.append(f"{pname}: names {len(subjects)} subjectRegExp, expected exactly one")
        continue
    expr = subjects[0]
    repos = {BINDINGS[n][0] for n in names if n in BINDINGS}
    wfs = {BINDINGS[n][1] for n in names if n in BINDINGS}
    if len(repos) != 1 or len(wfs) != 1:
        bad.append(f"{pname}: its globs name images of {len(repos)} repositories and {len(wfs)} workflows, expected one of each")
        continue
    repo, wf = repos.pop(), wfs.pop()
    try:
        rx = re.compile(expr)
    except re.error as e:
        bad.append(f"{pname}: subjectRegExp does not compile: {e}")
        continue
    if expr != subject_for(repo, wf):
        bad.append(f"{pname}: subjectRegExp is not the identity of {repo}'s {wf} on a version tag")
    if not rx.fullmatch(identity_of(repo, wf, "v2.2.1")):
        bad.append(f"{pname}: subjectRegExp refuses its own repository's release of {repo}")
    # every other binding's identity is refused: an image is admitted only on its own repository's signature
    for orepo, owf in set(BINDINGS.values()):
        if (orepo, owf) == (repo, wf):
            continue
        if rx.fullmatch(identity_of(orepo, owf, "v1.0.0")):
            bad.append(f"{pname}: subjectRegExp accepts the identity of another repository ({orepo}'s {owf}); "
                       f"an image of {repo} would be admitted on {orepo}'s signature")
    if rx.fullmatch(f"https://github.com/TAIPANBOX/{repo}/.github/workflows/{wf}@refs/heads/main"):
        bad.append(f"{pname}: subjectRegExp accepts a branch of {repo}, not only a version tag")
    if rx.fullmatch(f"https://github.com/evil-fork/{repo}/.github/workflows/{wf}@refs/tags/v1.0.0"):
        bad.append(f"{pname}: subjectRegExp accepts a fork's release (evil-fork/{repo})")
    if rx.fullmatch(identity_of(repo, wf, "v1.0.0") + "\nextra"):
        bad.append(f"{pname}: subjectRegExp accepts a value with a trailing line")

# Coverage: every name the stack knows is covered by exactly one policy, and every covered name is known.
for n in BINDINGS:
    if n not in cover:
        bad.append(f"ghcr.io/taipanbox/{n} is covered by no ClusterImagePolicy: refused by default, and this gate measured NOTHING about its signer")
for n in cover:
    if n not in BINDINGS:
        bad.append(f"ghcr.io/taipanbox/{n} has a policy but no row in BINDINGS in scripts/verified-images-are-enforced.sh")

# 4. Static allows: digest pinned, with a reason, and the same digests as the manifests name.
static_digests = {}


def norm(ref):
    """The name the admission controller matches a glob against: no tag, no digest, and Docker Hub's
    short names spelled out (postgres -> index.docker.io/library/postgres)."""
    base = ref.split("@", 1)[0]
    head, _, last = base.rpartition("/")
    last = last.split(":", 1)[0]
    base = head + "/" + last if head else last
    first = base.split("/", 1)[0]
    if "/" not in base:
        base = "index.docker.io/library/" + base
    elif "." not in first and ":" not in first and first != "localhost":
        base = "index.docker.io/" + base
    return base


for d in static_docs:
    if re.search(r"^\s*(-\s*)?static:", d, re.M) is None:
        continue
    for m in re.finditer(r"^\s*-\s*glob:\s*['\"]?([^'\"\s]+)['\"]?\s*$", d, re.M):
        glob = m.group(1)
        if "@sha256:" not in glob:
            bad.append(f"static allow is not pinned by digest: {glob}")
        name = norm(glob)
        digest = glob.split("@", 1)[1] if "@" in glob else ""
        static_digests[name] = digest
        lines = d.splitlines()
        idx = next((i for i, l in enumerate(lines) if glob in l), None)
        above = lines[idx - 1] if idx else ""
        if not re.match(r"^\s*#\s*reason:\s*\S", above):
            bad.append(f"static allow without a reason line above it: {glob}")
if not static_digests:
    bad.append("policy/image-policy.yaml names no static allow, so the upstream images have no trust decision")

# 5. up.sh: controller, wait for its webhook, policies, then the namespace label. Commands are read
#    as `kubectl ...` or as `$KUBECTL ...` (deploy.sh runs the script on the first node with k3s's kubectl).
up = read("policy/up.sh")
KC = r"(?:kubectl|\$KUBECTL)"
steps = []
for n, line in live_lines(up):
    if re.search(rf"{KC}\s+apply\b.*policy-controller\.yaml", line):
        steps.append(("apply-controller", n))
    if re.search(rf"{KC}\s+(-n\s+\S+\s+)?rollout\s+status\b.*webhook", line) or \
       re.search(rf"{KC}\s+wait\b.*webhook", line):
        steps.append(("wait-webhook", n))
    if re.search(rf"{KC}\s+apply\b.*image-policy\.yaml", line):
        steps.append(("apply-policies", n))
    if re.search(rf"{KC}\s+label\s+(--overwrite\s+)?namespace\s+agent-stack\s+policy\.sigstore\.dev/include=\"?true\"?", line):
        steps.append(("label", n))
order = [s for s, _ in steps]
for need in ("apply-controller", "wait-webhook", "apply-policies", "label"):
    if need not in order:
        if need == "label":
            bad.append("policy/up.sh does not label agent-stack with policy.sigstore.dev/include=true")
        elif need == "wait-webhook":
            bad.append("policy/up.sh does not wait for the webhook before admitting anything")
        else:
            bad.append(f"policy/up.sh has no {need} step")
if all(s in order for s in ("apply-controller", "wait-webhook", "apply-policies", "label")):
    pos = {s: n for s, n in steps}
    if not (pos["apply-controller"] < pos["wait-webhook"] < pos["apply-policies"] < pos["label"]):
        bad.append("policy/up.sh runs its steps out of order: the controller, then its webhook, then the policies, then the namespace")

# 6. Every image reference in a tracked file is pinned by digest, and every unsigned one is on the
#    list below with a reason.
ALLOW_UNPINNED = {
    # placeholder pod template for the agent-token example; the operator replaces it before apply
    ("agent-tokens/example-agent.yaml", "ghcr.io/taipanbox/agent-example:replace-with-a-pinned-tag"):
        "placeholder in an example pod template, replaced by the operator before apply",
    # built on the host by the tunnel's own script, running in agent-tunnel, which is not opted in
    ("tunnel/tunnel-pod.yaml", "stack/wg:dev"): "built on the host, in agent-tunnel, not opted in",
    ("tunnel/tunnel-pod.yaml", "stack/caddy:dev"): "built on the host, in agent-tunnel, not opted in",
    # upstream cloud controllers, applied into kube-system by the cloud installers, pinned by version
    # from the installer's own variable; kube-system is not opted in, so the policy does not cover them
    ("cloud/aws/install-aws.sh", "registry.k8s.io/provider-aws/cloud-controller-manager:$CCM_VERSION"):
        "upstream cloud controller in kube-system, not opted in; pinned by version, not digest",
    ("cloud/gcp/install-gcp.sh", "registry.k8s.io/cloud-provider-gcp/cloud-controller-manager:$CCM_VERSION"):
        "upstream cloud controller in kube-system, not opted in; pinned by version, not digest",
}
files = subprocess.run(["git", "ls-files", "*.yaml", "*.yml", "*.sh"], capture_output=True, text=True).stdout.split()
skip_prefixes = ("evidence/", "docs/", "features/", "policy/PIN", "policy/policy-controller.yaml", ".github/")
refs = []
for f in files:
    # the controller's own image is judged against policy/PIN in check 1, not here
    if f.startswith(skip_prefixes) or f == "scripts/gates-have-teeth.sh":
        continue
    try:
        text = read(f)
    except (OSError, UnicodeDecodeError):
        continue
    for n, line in live_lines(text):
        m = re.match(r"^\s*(?:-\s*)?image:\s*['\"]?([^'\"\s#]+)", line)
        if m:
            refs.append((f, n, m.group(1)))

if not refs:
    bad.append("no image reference found in any tracked YAML or shell file, so this gate measured NOTHING")

for f, n, img in refs:
    if "@sha256:" not in img:
        if (f, img) in ALLOW_UNPINNED:
            continue
        bad.append(f"image not pinned by digest: {f}:{n} {img}")
        continue
    name = img.split("@", 1)[0]
    if name.startswith("ghcr.io/taipanbox/"):
        short = name[len("ghcr.io/taipanbox/"):].split(":", 1)[0]
        if short not in BINDINGS:
            bad.append(f"{f}:{n} {img}: the TAIPANBOX image {short} has no signer row in BINDINGS, "
                       "so no policy can admit it")
        continue
    if static_digests.get(norm(name)) == img.split("@", 1)[1]:
        continue
    bad.append(f"{f}:{n} {img} is neither a TAIPANBOX image nor on the static allow list in policy/image-policy.yaml")

# 7. The default apply set does not name policy/, and deploy.sh turns admission on after its apply.
kust = read("manifests/kustomization.yaml") if os.path.exists("manifests/kustomization.yaml") else ""
if re.search(r"policy/", kust):
    bad.append("the default apply set names policy/, so the admission policy would be on by default in the manifests")
deploy_lines = [l for _, l in live_lines(read("deploy.sh"))]
apply_at = next((i for i, l in enumerate(deploy_lines) if re.search(r"apply -k /root/stack-k8s/manifests", l)), None)
enforce_at = next((i for i, l in enumerate(deploy_lines)
                   if re.search(r"policy/up\.sh\s+--enforce", l)), None)
if enforce_at is None:
    bad.append("deploy.sh does not turn admission on for agent-stack (policy/up.sh --enforce), so the default install is not admitted")
elif apply_at is None:
    bad.append("deploy.sh has no apply of the manifests, so its admission step has nothing to follow")
elif enforce_at < apply_at:
    bad.append("deploy.sh turns admission on before it applies the manifests, when the namespace does not exist yet")

if bad:
    for b in bad:
        print("FAIL " + b)
    sys.exit(1)

print(f"OK: {len(refs)} image reference(s) pinned by digest; {len(taipanbox_policies)} policies, one per repository, "
      f"cover {len(cover)} TAIPANBOX image names with the workflow of their own repository; {len(static_digests)} static "
      "allow(s) carry a reason; policy/up.sh waits for the webhook before it opts the namespace in; deploy.sh opts "
      "agent-stack in after its apply.")
PY
