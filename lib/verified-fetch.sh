# verified-fetch.sh: download a file other people publish ONCE, on the operator's
# machine, check its sha256 against a constant written in this file, and only then
# let anything use it.
#
# Sourced by install.sh, cloud/aws/install-aws.sh and cloud/gcp/install-gcp.sh
# (CLAUDE.md invariant 87). It replaces four unverified fetches that used to run
# on the nodes or straight into a shell: `kubectl apply -f https://.../longhorn.yaml`,
# the same for Hetzner's ccm-networks.yaml and Calico's tigera-operator.yaml, and
# `curl https://get.k3s.io | sh`, a floating script that is whatever the k3s
# project last published.
#
#   vf_init                                     once, in the main shell, before any fetch
#   vf_file <VAR> <what> <version> <url>        prints the path of the verified file
#   vf_cat  <VAR> <what> <version> <url>        prints the verified file's bytes
#   vf_cleanup                                  removes the scratch directory
#
# <VAR> names the environment variable that may carry the expected hash
# (LONGHORN_SHA256, HCLOUD_CCM_SHA256, K3S_INSTALL_SHA256, CALICO_SHA256). The
# expected hash is that variable when it is set, and otherwise the entry of the
# table below for exactly <VAR>@<version>. A version nobody pinned and no hash
# given STOPS, naming the variable: it is never a silent skip of the check.
#
# Nothing reaches stdout, and nothing is cached, unless the hash matched. A
# mismatch says which file, which URL, the hash expected and the hash received.
#
# To move a pin: download the file at the new version, READ it, take its sha256
# (`curl -fsSL <url> | sha256sum`), and write the new row. The old row can stay
# for an operator who pins the old version; scripts/remote-fetches-are-verified.sh
# only requires that the default version of each installer has a row.
#
# Needs curl and one of sha256sum or shasum. With neither hash tool it stops: a
# check that cannot be made is not a check that passed.

vf_pin() {
  case "$1@$2" in
    # https://raw.githubusercontent.com/longhorn/longhorn/v1.7.2/deploy/longhorn.yaml
    LONGHORN_SHA256@v1.7.2) printf '%s' 4fe30e43f0557d3242f3ac6011fc7badf1ec6107fc9ca1299f488ca7c9a57b00 ;;
    # https://github.com/hetznercloud/hcloud-cloud-controller-manager/releases/download/v1.21.0/ccm-networks.yaml
    HCLOUD_CCM_SHA256@v1.21.0) printf '%s' d9617a1c5de854a1b73700d82a67b0073bedd319fbcdc999a7b3be50497da45a ;;
    # https://raw.githubusercontent.com/k3s-io/k3s/v1.36.2%2Bk3s1/install.sh (the script at the release's tag, not get.k3s.io)
    K3S_INSTALL_SHA256@v1.36.2+k3s1) printf '%s' 46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad ;;
    # https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/tigera-operator.yaml
    CALICO_SHA256@v3.29.1) printf '%s' 1edc2f2b1acf50fa586c96839353d0e7247c603ee48e68f2a3e4354716de3730 ;;
    *) return 1 ;;
  esac
}

vf_init() {
  [ -n "${VF_DIR:-}" ] && [ -d "$VF_DIR" ] && return 0
  VF_DIR="$(mktemp -d "${TMPDIR:-/tmp}/verified-fetch.XXXXXX")" || {
    echo "verified-fetch: could not make a scratch directory" >&2
    return 1
  }
  chmod 700 "$VF_DIR"
}

vf_cleanup() {
  [ -n "${VF_DIR:-}" ] && [ -d "$VF_DIR" ] && rm -rf "$VF_DIR"
  VF_DIR=""
  return 0
}

vf_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    return 127
  fi
}

# vf_expected <VAR> <version>: the hash this fetch must match, or a refusal.
vf_expected() {
  local var="$1" ver="$2" given want
  given="${!var:-}"
  if [ -n "$given" ]; then
    want="$given"
  elif want="$(vf_pin "$var" "$ver")"; then
    :
  else
    echo "verified-fetch: no sha256 is pinned for $var at version $ver, and $var is not set." >&2
    echo "  Not fetching it unverified. Read the file at that version, take its sha256," >&2
    echo "  and give it: $var=<sha256> (or use the version this script pins)." >&2
    return 1
  fi
  case "$want" in
    *[!0-9a-f]* | "") want="" ;;
  esac
  if [ "${#want}" -ne 64 ]; then
    echo "verified-fetch: $var is not a lower-case sha256 (64 hex characters)" >&2
    return 1
  fi
  printf '%s' "$want"
}

vf_file() {
  local var="$1" what="$2" ver="$3" url="$4" want got tmp dest
  [ -n "${VF_DIR:-}" ] && [ -d "$VF_DIR" ] || {
    echo "verified-fetch: vf_init was not called" >&2
    return 1
  }
  want="$(vf_expected "$var" "$ver")" || return 1
  dest="$VF_DIR/$var-$want"
  if [ -f "$dest" ]; then
    # Cached by the hash it was verified against; checked again, it is cheap.
    got="$(vf_sha256 "$dest")" || { echo "verified-fetch: no sha256sum or shasum on this machine, so nothing was checked" >&2; return 1; }
    if [ "$got" = "$want" ]; then
      printf '%s' "$dest"
      return 0
    fi
    rm -f "$dest"
  fi
  tmp="$(mktemp "$VF_DIR/dl.XXXXXX")" || return 1
  if ! curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --connect-timeout 20 -o "$tmp" "$url"; then
    rm -f "$tmp"
    echo "verified-fetch: could not download $what from $url" >&2
    return 1
  fi
  got="$(vf_sha256 "$tmp")" || {
    rm -f "$tmp"
    echo "verified-fetch: no sha256sum or shasum on this machine, so $what was not checked and is not used" >&2
    return 1
  }
  if [ "$got" != "$want" ]; then
    rm -f "$tmp"
    echo "verified-fetch: sha256 mismatch for $what" >&2
    echo "  url:      $url" >&2
    echo "  expected: $want" >&2
    echo "  received: $got" >&2
    echo "  Nothing was applied or run. If you chose another version on purpose, read the file and set $var." >&2
    return 1
  fi
  mv "$tmp" "$dest" || return 1
  printf '%s' "$dest"
}

vf_cat() {
  local f
  f="$(vf_file "$@")" || return 1
  cat "$f"
}
