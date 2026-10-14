# The ONE secret generator in this repository, sourced by every script that mints
# a random value as text: deploy.sh, cloud/gcp/deploy-gcp.sh and
# cloud/aws/deploy-aws.sh for the operator password. Sourced, not run: it
# defines `gen` and does nothing else. CLAUDE.md invariant 41;
# scripts/gen-is-bounded.sh holds it.
#
#   . "$ROOT/lib/gen.sh"
#   v="$(gen 28)" || die "..."
#
# `tr </dev/urandom | head -c N` is the idiom everyone writes and it is a trap
# twice over, because tr reads a stream that never ends and only a closed pipe
# stops it. Under `set -o pipefail` the SIGPIPE that stops it fails the
# pipeline (141) and `set -e` ends the script there, silently (GOTCHAS 25).
# Turning pipefail off for that one pipeline, which is what this repository did
# for 25, fixes only that half: with SIGPIPE IGNORED, which is how git runs a
# hook and how some supervisors start a child, nothing stops tr at all. macOS's
# tr never exits, and GNU tr prints "write error: Broken pipe" on every call
# (GOTCHAS 125).
#
# So the read is bounded and nothing closes a pipe early: 4096 random bytes hold
# about 990 of the 62 characters on average, tr reads to the end of its input,
# and the cut to N is bash's own. The length check is what refuses a short
# value, and it says so on stderr and returns 1, so the caller's own `|| die`
# names the step. Ported from stack-single's install.sh (its invariant 31).
#
# Nothing else in this repository reads /dev/urandom except as
# `head -c <count> /dev/urandom`, which is bounded the same way.
# gen: begin
gen() {
  local n="${1:-40}" v
  v="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')" || v=""
  v="${v:0:$n}"
  if [ "${#v}" != "$n" ]; then
    printf "could not generate a %s-character secret (got %s); /dev/urandom is not readable.\n" "$n" "${#v}" >&2
    return 1
  fi
  printf '%s' "$v"
}
# gen: end
