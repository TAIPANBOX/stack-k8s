#!/usr/bin/env bash
# hub/add-site.sh reads the tokenfuse-cloud version from the Deployment's image. The manifests pin that image
# as name:tag@sha256:<64 hex>, so the reader must take the tag from before the digest, and must refuse a
# reference with no tag rather than read the digest as a tag. v1.5.3's reader took everything after the last
# colon, which is the digest, and refused every pinned image, so adding a site broke on the pinned install.
#
# This runs hub/add-site.sh up to the version check, against a stub kubectl that answers the three reads
# the script makes before that point and nothing else. The script then stops at the hub's public address,
# which the stub leaves unset, so no key is minted and nothing on any cluster is written.
#
#   1. name:tag                    -> the version is read (v1.19.0)
#   2. name:tag@sha256:<64 hex>    -> the version is read (v1.19.0), the form the manifests pin
#   3. host:port/name:tag@sha256:  -> the version is read; a registry port is not a tag
#   4. name@sha256:<64 hex>        -> refused: there is no tag to read
#   5. name:tag@sha256:<short>     -> refused: the digest is not 64 hex
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

fail=0
bad() { printf 'FAIL: %s\n' "$*"; fail=$((fail + 1)); }

SCRIPT="hub/add-site.sh"
if [ ! -f "$SCRIPT" ]; then
  bad "$SCRIPT is absent: the pinned-image read is measured NOTHING"
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# A read-only stub. It answers the three reads add-site.sh makes before the hub address, and nothing else.
case "$*" in
  "version -o json") echo '{}' ;;
  *"get deployment tokenfuse-cloud"*) printf '%s' "$STUB_IMAGE" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$tmp/bin/kubectl"

DIGEST="201f4dc7faf556f16038a5cc380f5945dc7b87b79a8ab7940402988844b17949"
run() { # run IMAGE: sets OUT (stdout and stderr)
  OUT="$(STUB_IMAGE="$1" PATH="$tmp/bin:$PATH" bash "$SCRIPT" probe-site 2>&1)" || true
}

run "ghcr.io/taipanbox/tokenfuse-control-plane:v1.19.0"
if ! printf '%s\n' "$OUT" | grep -qF "tokenfuse-cloud is v1.19.0, at or above v1.2.0"; then
  bad "a bare name:tag is not read: $(printf '%s' "$OUT" | tail -1)"
fi

run "ghcr.io/taipanbox/tokenfuse-control-plane:v1.19.0@sha256:$DIGEST"
if ! printf '%s\n' "$OUT" | grep -qF "tokenfuse-cloud is v1.19.0, at or above v1.2.0"; then
  bad "a name:tag@sha256:<64 hex> reference, the form the manifests pin, is not read: $(printf '%s' "$OUT" | tail -1)"
fi

run "localhost:5000/tokenfuse-control-plane:v1.19.0@sha256:$DIGEST"
if ! printf '%s\n' "$OUT" | grep -qF "tokenfuse-cloud is v1.19.0, at or above v1.2.0"; then
  bad "a registry with a port is read as the tag: $(printf '%s' "$OUT" | tail -1)"
fi

run "ghcr.io/taipanbox/tokenfuse-control-plane@sha256:$DIGEST"
if ! printf '%s\n' "$OUT" | grep -qF "has no vX.Y.Z tag this script can read"; then
  bad "a digest with no tag is not refused: $(printf '%s' "$OUT" | tail -1)"
fi

run "ghcr.io/taipanbox/tokenfuse-control-plane:v1.19.0@sha256:abc123"
if ! printf '%s\n' "$OUT" | grep -qF "is not a sha256 digest of 64 hex"; then
  bad "a short digest is not refused: $(printf '%s' "$OUT" | tail -1)"
fi

if [ "$fail" -gt 0 ]; then
  printf '%d problem(s). The pinned image reference is read by hub/add-site.sh.\n' "$fail"
  exit 1
fi
echo "OK: hub/add-site.sh reads the tokenfuse-cloud version from a bare name:tag and from name:tag@sha256:<64 hex>, refuses a digest with no tag and a short digest."
