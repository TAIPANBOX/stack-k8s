# The browser's seccomp profile, put on a node before k3s starts there.
#
#   browser_seccomp_put HELPER NODE     HELPER is the installer's root ssh helper (sh_ or su_)
#
# WHY A NODE FILE
#
# `manifests/48-scopyx-browser.yaml` runs Chromium with its own sandbox on, which needs a
# user, pid and net namespace and a chroot. The runtime's default filter refuses all three
# (GOTCHAS 83), and Pod Security `restricted`, the level of `agent-stack`, refuses
# `Unconfined` (GOTCHAS 84) but admits a `Localhost` profile. The kubelet reads a Localhost
# profile from a file under its own directory on the node the pod lands on, so the file has
# to be on EVERY node, and the installer is the one thing here that already writes files
# onto every node as root (the graceful-shutdown drop-ins, invariant 46). No new component
# runs in the cluster for it, privileged or not. CLAUDE.md invariant 84.
#
# WHAT GOES THERE
#
# `seccomp/chromium-v1.json`, the OCI form of stack-single's profile that `seccomp/resolve.py`
# prints, never the Docker-format file: containerd drops Docker's conditions without a word
# and the profile would allow mount, setns and every namespace (GOTCHAS 161). It lands at
# /var/lib/kubelet/seccomp/taipanbox/chromium-v1.json, which is the kubelet's seccomp root on
# k3s joined to the `localhostProfile` the manifest names. A changed profile is a new name
# (chromium-v2), never new bytes under this one: the kubelet reads the file when it creates a
# container, so new bytes under the old name would change a running browser's filter at its
# next restart with no change to the pod.
#
# WHEN IT IS NOT THERE
#
# The kubelet does not fall back. containerd refuses to create the container, and the pod
# shows CreateContainerError with `cannot load seccomp profile
# "/var/lib/kubelet/seccomp/taipanbox/chromium-v1.json"`. Writing the file and waiting is the
# whole repair: the kubelet retries. `verify.sh` names the file and this step when it sees it.
#
# Written through a temporary name and moved into place, so a browser starting while an
# installer runs reads the old file or the new one, never half of one. Sourced by
# install.sh, cloud/gcp/install-gcp.sh and cloud/aws/install-aws.sh.

BROWSER_SECCOMP_ROOT=/var/lib/kubelet/seccomp
BROWSER_SECCOMP_NAME=taipanbox/chromium-v1.json
BROWSER_SECCOMP_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/seccomp/chromium-v1.json"

browser_seccomp_put() { # HELPER NODE
  local helper="$1" node="$2" dir file
  dir="$BROWSER_SECCOMP_ROOT/$(dirname "$BROWSER_SECCOMP_NAME")"
  file="$BROWSER_SECCOMP_ROOT/$BROWSER_SECCOMP_NAME"
  if [ ! -s "$BROWSER_SECCOMP_FILE" ]; then
    printf 'the browser seccomp profile %s is not in this checkout\n' "$BROWSER_SECCOMP_FILE" >&2
    return 1
  fi
  "$helper" "$node" "sh -c 'umask 022 && mkdir -p $dir && cat > $file.new && mv -f $file.new $file'" \
    <"$BROWSER_SECCOMP_FILE"
}
