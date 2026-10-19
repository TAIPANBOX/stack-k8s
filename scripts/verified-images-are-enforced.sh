#!/usr/bin/env bash
# Enforces invariant 58 of CLAUDE.md: the opt-in admission policy admits only
# images whose signature verifies, every image the stack names is pinned by
# digest, and the one thing the policy trusts without a signature is listed,
# with a reason, next to the digest it trusts.
#
# WHY
#
# A launcher that pins by tag and pulls whatever the registry serves today runs
# a different image after every re-push of that tag, and nothing on the cluster
# says so. Every TAIPANBOX release is signed keyless by its own release workflow
# (the signature and the build provenance sit on the registry next to the image),
# but no launcher checks that before it runs an image. The approved method is the
# Sigstore policy-controller, with a ClusterImagePolicy that names the expected
# signer, installed by policy/up.sh and switched on per namespace.
#
# WHAT THIS CHECKS
#
#   1. policy/PIN records the controller release, its source commit, the one image
#      it runs by digest, and the sha256 of the rendered manifest; the manifest on
#      disk is that file, byte for byte, and names that image and no other.
#   2. policy/image-policy.yaml has a keyless ClusterImagePolicy for
#      ghcr.io/taipanbox/** in enforce mode, whose issuer is GitHub Actions and
#      whose subject accepts the release workflow on a version tag of a TAIPANBOX
#      repository and nothing else. Its subject expression is run against the
#      identities measured on the registry, and against identities it must refuse.
#   3. Every static (unsigned) allow is pinned by digest and carries a reason, and
#      the digests in the manifests are the digests the static allows name.
#   4. policy/up.sh installs the controller, waits for its webhook, applies the
#      policies and only then opts the stack's namespace in.
#   5. Every image reference in a tracked YAML or shell file is pinned by digest.
#      A TAIPANBOX image is covered by the glob; an upstream image must be one of
#      the static allows; the rest of the exceptions are listed below with reasons.
#   6. The default apply set (manifests/kustomization.yaml) does not name policy/.
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

for needed in ("policy/PIN", "policy/policy-controller.yaml", "policy/image-policy.yaml", "policy/up.sh"):
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

# 2. The keyless policy: enforce, the TAIPANBOX glob, GitHub Actions, release workflow on a version tag.
ip = read("policy/image-policy.yaml")
docs = [d for d in re.split(r"\n---\s*\n", ip) if re.search(r"^kind:\s*ClusterImagePolicy\s*$", d, re.M)]
by_name = {}
for d in docs:
    m = re.search(r"^  name:\s*(\S+)\s*$", d, re.M)
    if m:
        by_name[m.group(1)] = d
signed = by_name.get("taipanbox-signed")
if signed is None:
    bad.append("policy/image-policy.yaml has no ClusterImagePolicy named taipanbox-signed, so this gate measured NOTHING about the signer")
    signed = ""

GLOB = "ghcr.io/taipanbox/**"
ISSUER = "https://token.actions.githubusercontent.com"
SUBJECT_RE = r"^https://github\.com/TAIPANBOX/[A-Za-z0-9._-]+/\.github/workflows/release\.yml@refs/tags/v[0-9][A-Za-z0-9._+-]*$"

if signed:
    if not re.search(rf"glob:\s*['\"]?{re.escape(GLOB)}['\"]?\s*$", signed, re.M):
        bad.append(f"taipanbox-signed does not match {GLOB}")
    if not re.search(rf"issuer:\s*['\"]?{re.escape(ISSUER)}['\"]?\s*$", signed, re.M):
        bad.append(f"taipanbox-signed issuer is not {ISSUER}")
    if not re.search(r"^\s*mode:\s*enforce\s*$", signed, re.M):
        bad.append("taipanbox-signed mode is not enforce (a warn policy admits the unsigned image)")
    m = re.search(r"subjectRegExp:\s*['\"]?(.+?)['\"]?\s*$", signed, re.M)
    if not m:
        bad.append("taipanbox-signed names no subjectRegExp")
    else:
        expr = m.group(1)
        try:
            rx = re.compile(expr)
        except re.error as e:
            rx = None
            bad.append(f"taipanbox-signed subjectRegExp does not compile: {e}")
        if rx is not None:
            must = [
                "https://github.com/TAIPANBOX/wardryx/.github/workflows/release.yml@refs/tags/v2.1.0",
                "https://github.com/TAIPANBOX/tokenfuse/.github/workflows/release.yml@refs/tags/v1.16.0",
                "https://github.com/TAIPANBOX/agent-stack-go/.github/workflows/release.yml@refs/tags/v1.1.0",
                "https://github.com/TAIPANBOX/trailryx/.github/workflows/release.yml@refs/tags/v1.2.1",
            ]
            refuse = [
                "https://github.com/evil-fork/wardryx/.github/workflows/release.yml@refs/tags/v2.1.0",
                "https://github.com/TAIPANBOX/wardryx/.github/workflows/ci.yml@refs/heads/main",
                "https://github.com/TAIPANBOX/wardryx/.github/workflows/release.yml@refs/heads/main",
                "https://github.com/TAIPANBOX/wardryx/.github/workflows/release.yml@refs/tags/v2.1.0/../../x",
                "https://github.com/TAIPANBOX/wardryx/.github/workflows/release.yml@refs/tags/v2.1.0\nextra",
            ]
            for s in must:
                if not rx.fullmatch(s):
                    bad.append(f"taipanbox-signed subjectRegExp refuses a release of TAIPANBOX: {s}")
            for s in refuse:
                if rx.fullmatch(s):
                    bad.append(f"taipanbox-signed subjectRegExp accepts a foreign or non-release identity: {s}")
        if expr != SUBJECT_RE:
            bad.append("taipanbox-signed subjectRegExp is not the release-workflow expression recorded in this gate")

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


# 3. Static allows: digest pinned, with a reason, and the same digests as the manifests name.
static_docs = [d for d in docs if d is not signed]
static_digests = {}
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
        # the reason is a comment line immediately above the glob
        lines = d.splitlines()
        idx = next((i for i, l in enumerate(lines) if glob in l), None)
        above = lines[idx - 1] if idx else ""
        if not re.match(r"^\s*#\s*reason:\s*\S", above):
            bad.append(f"static allow without a reason line above it: {glob}")
if not static_digests:
    bad.append("policy/image-policy.yaml names no static allow, so the upstream images have no trust decision")

# 4. up.sh: controller, wait for its webhook, policies, then the namespace label.
up = read("policy/up.sh")
steps = []
for n, line in live_lines(up):
    if re.search(r"kubectl\s+apply\b.*policy-controller\.yaml", line):
        steps.append(("apply-controller", n))
    if re.search(r"kubectl\s+(-n\s+\S+\s+)?rollout\s+status\b.*webhook", line) or \
       re.search(r"kubectl\s+wait\b.*webhook", line):
        steps.append(("wait-webhook", n))
    if re.search(r"kubectl\s+apply\b.*image-policy\.yaml", line):
        steps.append(("apply-policies", n))
    if re.search(r"kubectl\s+label\s+(--overwrite\s+)?namespace\s+agent-stack\s+policy\.sigstore\.dev/include=\"?true\"?", line):
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

# 5. Every image reference in a tracked file is pinned by digest, and every
#    unsigned one is on the list below with a reason.
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
    # the controller's own image is judged against policy/PIN in section 1, not here
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

checked_upstream = {}
for f, n, img in refs:
    if "@sha256:" not in img:
        if (f, img) in ALLOW_UNPINNED:
            continue
        bad.append(f"image not pinned by digest: {f}:{n} {img}")
        continue
    name = img.split("@", 1)[0]
    if name.startswith("ghcr.io/taipanbox/"):
        if not name.startswith("ghcr.io/taipanbox/"):
            bad.append(f"{f}:{n} {img} is not under {GLOB}")
        continue
    if static_digests.get(norm(name)) == img.split("@", 1)[1]:
        checked_upstream[norm(name)] = True
        continue
    bad.append(f"{f}:{n} {img} is neither a TAIPANBOX image nor on the static allow list in policy/image-policy.yaml")

# 6. The default apply set does not name policy/.
kust = read("manifests/kustomization.yaml") if os.path.exists("manifests/kustomization.yaml") else ""
if re.search(r"policy/", kust):
    bad.append("the default apply set names policy/, so the admission policy would be on by default")

if bad:
    for b in bad:
        print("FAIL " + b)
    sys.exit(1)

print(f"OK: {len(refs)} image reference(s) pinned by digest; every TAIPANBOX image falls under "
      f"{GLOB} with the release-workflow identity; {len(static_digests)} static allow(s) carry a reason; "
      "policy/up.sh waits for the webhook before it opts the namespace in.")
PY
