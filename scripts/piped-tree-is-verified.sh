#!/usr/bin/env bash
#
# Enforces CLAUDE.md invariant 94: a piped deploy runs only a release tree whose signed bundle cosign
# verified for this repository's release workflow at exactly that tag; main only when asked, unsigned
# and said so; no fallback between them.
#
# WHY
#
# Until 2026-11-23 `curl .../main/deploy.sh | bash` fetched `tarball/$REF` with REF=main and ran it:
# whatever main held at that second, from a host nobody checked, with nothing to say which commit ran.
# The decision (`@decided 2026-11-23`, the stack revision wave): a piped install takes the latest
# release tag and verifies the tree with a cosign-signed bundle; main only by an explicit flag.
#
# WHAT THIS CHECKS
#
#   Static
#   1. deploy.sh holds one `# tree-bootstrap: begin` ... `# tree-bootstrap: end` block, and section 0
#      calls tree_bootstrap only when this copy has no tree beside it.
#   2. The signer is the exact identity of release.yml at refs/tags/, with the Actions issuer; no
#      `--certificate-identity-regexp` anywhere; STACK_SIGNER is set once and from no variable.
#   3. In the block, `cosign verify-blob` comes before the first `tar -x`, and the tree's deploy.sh is
#      run only after the RELEASE check.
#   4. No tracked text tells an operator to pipe main: no raw.githubusercontent.com/.../main/deploy.sh.
#   5. .github/workflows/release.yml runs on v* tags with id-token: write, signs with
#      `cosign sign-blob --bundle`, verifies with the same exact identity and issuer, and attaches
#      stack-k8s.tar.gz, its .sigstore.json, its .sha256 and deploy.sh.
#   Behavioural: the block is lifted out of deploy.sh and run with a stub curl and a stub cosign on
#   PATH, the pinned cosign SHA-256 replaced in the lifted copy by the stub's (the copy is the test's;
#   deploy.sh carries no override), over a release fixture:
#   A  the latest release, signed: its tree's deploy.sh runs with the arguments, marked verified, and
#      cosign was asked for exactly release.yml@refs/tags/<tag> and the Actions issuer
#   B  cosign refuses: nothing is extracted and nothing runs
#   C  no bundle on the release: refused
#   D  a cosign binary that is not the pinned one: refused, and it never runs
#   E  a signed tree whose RELEASE names another tag: refused, nothing runs
#   F  a member outside stack-k8s/: refused before extraction
#   G  a link in the tree: refused before extraction
#   H  STACK_TAG that is not vX.Y.Z: refused
#   I  REF set: refused, not ignored
#   J  INSTALL_FROM_MAIN=1 with STACK_TAG: refused
#   K  INSTALL_FROM_MAIN=1: main, said UNSIGNED, no cosign
#   L  STACK_TAG=v9.9.7: that tag's identity, and /latest is never asked
#
# A deploy.sh with no block, or no release workflow, is "measured NOTHING", never a pass.
set -uo pipefail
cd "$(dirname "$0")/.."

bad=0
fail() { printf 'FAIL %s\n' "$*"; bad=$((bad + 1)); }

DEPLOY=deploy.sh
WF=.github/workflows/release.yml
SIGNER='https://github.com/TAIPANBOX/stack-k8s/.github/workflows/release.yml@refs/tags/'
ISSUER='https://token.actions.githubusercontent.com'

if [ ! -f "$DEPLOY" ]; then
	echo "FAIL $DEPLOY is absent: the piped deploy is measured NOTHING"
	exit 1
fi
deploy="$(cat "$DEPLOY")"
nb="$(grep -c '^# tree-bootstrap: begin' <<<"$deploy")"
ne="$(grep -c '^# tree-bootstrap: end' <<<"$deploy")"
if [ "$nb" != 1 ] || [ "$ne" != 1 ]; then
	echo "FAIL $DEPLOY has $nb tree-bootstrap begin and $ne end markers, expected one each: the bootstrap is measured NOTHING"
	exit 1
fi
block="$(awk '/^# tree-bootstrap: begin/{on=1} on{print} /^# tree-bootstrap: end/{on=0}' "$DEPLOY")"
live="$(grep -v '^[[:space:]]*#' <<<"$block")"

# ---- 1. section 0 calls the bootstrap only without a tree beside it ----
after="$(awk '/^# tree-bootstrap: end/{on=1; next} on{print}' "$DEPLOY" | sed -n '1,30p')"
# The section-0 text after the block, through the fi that closes its checkout test, for case M.
section0="$(awk '/^# tree-bootstrap: end/{on=1; next} on{print} on && /^  tree_bootstrap$/{t=1} t && /^fi$/{exit}' "$DEPLOY")"
if ! grep -Eq '^if \[ -n "\$HERE" \] && \[ -d "\$HERE/manifests" \]; then' <<<"$after"; then
	fail "$DEPLOY: section 0 no longer starts with the checkout test right after the bootstrap block"
fi
if ! awk '/^else$/{e=1} e && /^  tree_bootstrap$/{f=1} END{exit !f}' <<<"$after"; then
	fail "$DEPLOY: section 0 does not call tree_bootstrap in its else branch"
fi
if grep -Fq 'BASH_SOURCE[0]:-$0' <<<"$after" || ! grep -Fq 'if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then' <<<"$after"; then
	fail "$DEPLOY: a checkout is not decided by this file being a real file on disk, so a piped run from a directory with manifests/ runs that directory unverified"
fi
grep -Fq '[ -z "${STACK_TREE_VERIFIED:-}${STACK_TREE_UNSIGNED:-}" ]' <<<"$live" \
	|| fail "$DEPLOY: a fetched tree's deploy.sh can enter the bootstrap again"

# ---- 2. the exact signer and issuer ----
if [ "$(grep -c '^STACK_SIGNER=' <<<"$live")" != 1 ] || ! grep -Fqx "STACK_SIGNER=\"$SIGNER\"" <<<"$live"; then
	fail "$DEPLOY: STACK_SIGNER is not set once to the literal $SIGNER"
fi
if ! grep -Fqx "STACK_ISSUER=\"$ISSUER\"" <<<"$live"; then
	fail "$DEPLOY: STACK_ISSUER is not the literal $ISSUER"
fi
if grep -q -- '--certificate-identity-regexp\|--certificate-oidc-issuer-regexp' "$DEPLOY" "$WF" 2>/dev/null; then
	fail "a regexp identity is accepted somewhere: the signer must be exact"
fi
if ! grep -Fq -- '--certificate-identity "$STACK_SIGNER$tag" --certificate-oidc-issuer "$STACK_ISSUER"' <<<"$live"; then
	fail "$DEPLOY: verify-blob is not asked for \$STACK_SIGNER\$tag and \$STACK_ISSUER"
fi

# ---- 3. order inside the block ----
lv="$(grep -n 'verify-blob' <<<"$live" | head -1 | cut -d: -f1)"
lx="$(grep -n 'tar -xzf\|tar -xz ' <<<"$live" | grep -v 'INSTALL_FROM_MAIN\|STACK_MAIN_TARBALL' | head -1 | cut -d: -f1)"
lmain="$(grep -n 'STACK_MAIN_TARBALL" | tar' <<<"$live" | head -1 | cut -d: -f1)"
lr="$(grep -n 'ROOT/RELEASE' <<<"$live" | head -1 | cut -d: -f1)"
le="$(grep -n 'exec env STACK_TREE_VERIFIED=' <<<"$live" | head -1 | cut -d: -f1)"
if [ -z "$lv" ] || [ -z "$lx" ]; then
	fail "$DEPLOY: the block has no verify-blob or no extraction of the release tree"
else
	# The release tree's extraction is the one after the main branch's return.
	lx="$(awk -v m="${lmain:-0}" 'NR > m && /tar -xzf/ {print NR; exit}' <<<"$live")"
	[ -n "$lx" ] && [ "$lv" -lt "$lx" ] || fail "$DEPLOY: the release tree is extracted before cosign verifies it"
fi
if [ -z "$lr" ] || [ -z "$le" ] || [ "$lr" -gt "$le" ]; then
	fail "$DEPLOY: the verified tree's deploy.sh is not run after its RELEASE check (or one of them is gone)"
fi

# ---- 4. nothing tells an operator to pipe main ----
hits="$(git grep -n 'raw.githubusercontent.com/TAIPANBOX/stack-k8s/main/deploy.sh' -- . ':!GOTCHAS.md' ':!docs/releases' ':!evidence' ':!scripts/piped-tree-is-verified.sh' ':!scripts/gates-have-teeth.sh' 2>/dev/null || true)"
if [ -n "$hits" ]; then
	fail "an operator is still told to pipe main: ${hits%%$'\n'*}"
fi

# ---- 5. the release workflow ----
if [ ! -f "$WF" ]; then
	fail "$WF is absent: the signed tree is measured NOTHING"
else
	wf="$(grep -v '^[[:space:]]*#' "$WF")"
	grep -Eq 'tags: \["v\*"\]' <<<"$wf" || fail "$WF does not run on v* tags"
	grep -q 'id-token: write' <<<"$wf" || fail "$WF has no id-token: write, so it cannot sign keyless"
	grep -q 'cosign sign-blob --yes --bundle dist/stack-k8s.tar.gz.sigstore.json dist/stack-k8s.tar.gz' <<<"$wf" \
		|| fail "$WF does not sign stack-k8s.tar.gz into stack-k8s.tar.gz.sigstore.json"
	grep -Fq -- "--certificate-identity \"$SIGNER\$TAG\"" <<<"$wf" || fail "$WF does not verify its signature for the exact identity the deploy asks for"
	grep -Fq -- "--certificate-oidc-issuer $ISSUER" <<<"$wf" || fail "$WF does not verify the Actions issuer"
	for a in dist/stack-k8s.tar.gz dist/stack-k8s.tar.gz.sigstore.json dist/stack-k8s.tar.gz.sha256 dist/deploy.sh; do
		grep -Fq "$a" <<<"$(grep '^ *assets=' <<<"$wf")" || fail "$WF does not attach $a"
	done
	grep -Fq 'git merge-base --is-ancestor "$tag" origin/main' <<<"$wf" || fail "$WF signs a tag that need not be on main's history"
	grep -q 'add-virtual-file="stack-k8s/RELEASE:$TAG"' <<<"$wf" || fail "$WF does not write stack-k8s/RELEASE into the archive (--add-virtual-file ignores --prefix)"
fi

# ---- behavioural ----
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/fix" "$T/tmp"
LOG="$T/log"

# The stub cosign is served by the stub curl as the "downloaded" binary.
cat >"$T/fix/cosign" <<'EOF'
#!/bin/sh
echo "cosign $*" >>"$PIPED_LOG"
[ "$1" = verify-blob ] || exit 2
id=""; iss=""
while [ $# -gt 0 ]; do
  case "$1" in --certificate-identity) id="$2"; shift ;; --certificate-oidc-issuer) iss="$2"; shift ;; esac
  shift
done
[ -f "$PIPED_FIX/verify-ok" ] || { echo "Error: none of the expected identities matched what was in the certificate"; exit 1; }
[ "$id" = "$PIPED_EXPECT_ID" ] && [ "$iss" = "https://token.actions.githubusercontent.com" ] \
  || { echo "Error: identity $id / $iss"; exit 1; }
echo "Verified OK"
EOF
cp "$T/fix/cosign" "$T/fix/other-cosign"
printf '\n# not the pinned binary\n' >>"$T/fix/other-cosign"

cat >"$T/bin/curl" <<'EOF'
#!/bin/sh
out=""; url=""; head=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -w) shift ;;
    --config) [ "$2" = - ] && cat >/dev/null; shift ;;
    -fsSI) head=1 ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
echo "curl $url" >>"$PIPED_LOG"
case "$url" in
  */releases/latest) [ "$head" = 1 ] || exit 22; printf '%s' "https://github.com/TAIPANBOX/stack-k8s/releases/tag/$PIPED_LATEST"; exit 0 ;;
  */cosign/releases/download/*) src="$PIPED_FIX/${PIPED_COSIGN:-cosign}" ;;
  */download/*/stack-k8s.tar.gz) src="$PIPED_FIX/stack-k8s.tar.gz" ;;
  */download/*/stack-k8s.tar.gz.sigstore.json) src="$PIPED_FIX/bundle" ;;
  */tarball/main) src="$PIPED_FIX/main.tar.gz" ;;
  *) exit 22 ;;
esac
[ -f "$src" ] || exit 22
if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
EOF
# tar is real, and every call is written down, so "nothing was extracted" is read from what ran.
real_tar="$(command -v tar)"
printf '#!/bin/sh\necho "tar $*" >>"$PIPED_LOG"\nexec "%s" "$@"\n' "$real_tar" >"$T/bin/tar"
chmod 0755 "$T/bin/curl" "$T/bin/tar" "$T/fix/cosign" "$T/fix/other-cosign"

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
stub_sha="$(sha "$T/fix/cosign")"

mktree() { # DIR RELEASE [extra]: a release archive at $T/fix/stack-k8s.tar.gz
	local d="$T/src/$1"
	rm -rf "$T/src" && mkdir -p "$d/stack-k8s/manifests"
	printf '%s' "$2" >"$d/stack-k8s/RELEASE"
	printf '#!/bin/sh\necho "TREE-RAN verified=$STACK_TREE_VERIFIED args=$*" >>"$PIPED_LOG"\n' >"$d/stack-k8s/deploy.sh"
	case "${3:-}" in
		outside) mkdir -p "$d/other" && echo x >"$d/other/x" ;;
		link) ln -s /etc/passwd "$d/stack-k8s/passwd" ;;
	esac
	if [ "${3:-}" = outside ]; then
		tar -czf "$T/fix/stack-k8s.tar.gz" -C "$d" stack-k8s other
	else
		tar -czf "$T/fix/stack-k8s.tar.gz" -C "$d" stack-k8s
	fi
}
mkrelease() { # TAG: the release archive built by release.yml's own `git archive` line, from a scratch repo
	local r="$T/repo" cmd
	rm -rf "$r" && mkdir -p "$r/manifests" "$r/dist"
	printf '#!/bin/sh\necho "TREE-RAN verified=$STACK_TREE_VERIFIED args=$*" >>"$PIPED_LOG"\n' >"$r/deploy.sh"
	touch "$r/manifests/.keep"
	cmd="$(awk '/git archive /{on=1} on{print} on && !/\\$/{exit}' "$WF")"
	[ -n "$cmd" ] || { fail "$WF has no git archive line to build the release with"; return 1; }
	(
		cd "$r" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
		git init -q && git -c user.name=t -c user.email=t@t add -A && git -c user.name=t -c user.email=t@t commit -qm t \
			&& git tag "$1" && TAG="$1" && REF="$1" && eval "$cmd"
	) >"$T/archive.log" 2>&1 || { fail "release.yml's git archive line did not run: $(tail -n 1 "$T/archive.log")"; return 1; }
	cp "$r/dist/stack-k8s.tar.gz" "$T/fix/stack-k8s.tar.gz"
}
mkmain() {
	rm -rf "$T/srcm" && mkdir -p "$T/srcm/TAIPANBOX-stack-k8s-abc123/manifests"
	echo main >"$T/srcm/TAIPANBOX-stack-k8s-abc123/MAIN"
	printf '#!/bin/sh\necho "TREE-RAN unsigned=$STACK_TREE_UNSIGNED verified=${STACK_TREE_VERIFIED:-} args=$*" >>"$PIPED_LOG"\n' >"$T/srcm/TAIPANBOX-stack-k8s-abc123/deploy.sh"
	tar -czf "$T/fix/main.tar.gz" -C "$T/srcm" TAIPANBOX-stack-k8s-abc123
}

# The lifted block, with the pinned hashes replaced by the stub's in this copy only.
lifted="$(sed -E "s/^(COSIGN_SHA256_[a-z_0-9]+)=\"[0-9a-f]{64}\"$/\\1=\"$stub_sha\"/" <<<"$block")"
if [ "$(grep -c "=\"$stub_sha\"" <<<"$lifted")" != 4 ]; then
	fail "$DEPLOY: the block does not pin four cosign SHA-256 values in the shape COSIGN_SHA256_<os>_<arch>=\"<64 hex>\""
fi
cat >"$T/run.sh" <<EOF
set -euo pipefail
say() { printf '>> %s\n' "\$*"; }
die() { printf '!! %s\n' "\$*" >&2; exit 1; }
CONSOLE_TOKEN=""
STACK_ARGS=(--servers 1.2.3.4 --no-tunnel)
$lifted
tree_bootstrap
echo "RETURNED ROOT=\$ROOT"
EOF

run() { # NAME ENV...: runs the lifted block, output in $T/out, exit in $rc
	: >"$LOG"
	rm -rf "$T/tmp" && mkdir -p "$T/tmp"
	env -u REF -u STACK_TAG -u INSTALL_FROM_MAIN PATH="$T/bin:$PATH" TMPDIR="$T/tmp" PIPED_LOG="$LOG" PIPED_FIX="$T/fix" \
		PIPED_LATEST=v9.9.9 PIPED_EXPECT_ID="${SIGNER}v9.9.9" "${@:2}" bash "$T/run.sh" >"$T/out" 2>&1
	rc=$?
}
ran_tree() { grep -q '^TREE-RAN' "$LOG"; }
extracted() { grep -Eq '^tar -x' "$LOG"; }

{
	mkrelease v9.9.9; touch "$T/fix/verify-ok"; echo '{}' >"$T/fix/bundle"; mkmain

	run A
	# The archive is release.yml's own, so a RELEASE the workflow writes where the bootstrap does not
	# look fails here, as it would on every real release.
	if [ "$rc" != 0 ] || ! grep -q '^TREE-RAN verified=v9.9.9 args=--servers 1.2.3.4 --no-tunnel$' "$LOG"; then
		fail "A: the latest signed release did not run its tree's deploy.sh with the arguments (rc=$rc): $(tail -n 2 "$T/out" | tr '\n' ' ')"
	fi
	if ! grep -Fq -- "--certificate-identity ${SIGNER}v9.9.9 --certificate-oidc-issuer $ISSUER" "$LOG"; then
		fail "A: cosign was not asked for exactly ${SIGNER}v9.9.9 and $ISSUER"
	fi
	grep -q '^curl .*/releases/latest$' "$LOG" || fail "A: the latest release was not asked for"

	rm -f "$T/fix/verify-ok"
	run B
	if [ "$rc" = 0 ] || ran_tree || extracted; then
		fail "B: a tree cosign refused was extracted or run (rc=$rc)"
	fi
	touch "$T/fix/verify-ok"

	mv "$T/fix/bundle" "$T/fix/bundle.away"
	run C
	{ [ "$rc" != 0 ] && grep -q 'carries no signed bundle' "$T/out" && ! ran_tree; } || fail "C: a release with no bundle was not refused for it (rc=$rc)"
	mv "$T/fix/bundle.away" "$T/fix/bundle"

	run D PIPED_COSIGN=other-cosign
	{ [ "$rc" != 0 ] && grep -q 'does not match its pinned SHA-256' "$T/out" && ! grep -q '^cosign ' "$LOG"; } \
		|| fail "D: a cosign that is not the pinned one was run or not refused (rc=$rc)"

	mktree ok v9.9.8
	run E
	{ [ "$rc" != 0 ] && ! ran_tree; } || fail "E: a signed tree whose RELEASE names another tag ran (rc=$rc)"

	mktree ok v9.9.9 outside
	run F
	{ [ "$rc" != 0 ] && ! extracted && grep -q 'outside stack-k8s/' "$T/out"; } || fail "F: a member outside stack-k8s/ was not refused before extraction (rc=$rc)"

	mktree ok v9.9.9 link
	run G
	{ [ "$rc" != 0 ] && ! extracted && grep -q 'carries a link' "$T/out"; } || fail "G: a link in the tree was not refused before extraction (rc=$rc)"

	mktree ok v9.9.9
	run H STACK_TAG=main
	{ [ "$rc" != 0 ] && grep -q 'is not a release tag' "$T/out"; } || fail "H: STACK_TAG=main was not refused as a tag (rc=$rc)"

	run I REF=main
	{ [ "$rc" != 0 ] && grep -q 'REF is no longer read' "$T/out"; } || fail "I: REF=main was ignored rather than refused (rc=$rc)"

	run J INSTALL_FROM_MAIN=1 STACK_TAG=v9.9.9
	{ [ "$rc" != 0 ] && grep -q 'two different trees' "$T/out"; } || fail "J: INSTALL_FROM_MAIN=1 with STACK_TAG was not refused (rc=$rc)"

	run K INSTALL_FROM_MAIN=1
	{ [ "$rc" = 0 ] && grep -q 'UNSIGNED' "$T/out" && ! grep -q '^cosign ' "$LOG" \
		&& grep -q '^TREE-RAN unsigned=main verified= args=--servers 1.2.3.4 --no-tunnel$' "$LOG"; } \
		|| fail "K: INSTALL_FROM_MAIN=1 did not run main's own deploy.sh, unsigned and said so, without cosign (rc=$rc): $(tail -n 1 "$T/out")"

	run N STACK_TREE_VERIFIED=v9.9.9
	{ [ "$rc" != 0 ] && grep -q 'found no manifests' "$T/out" && ! grep -q '^curl ' "$LOG"; } \
		|| fail "N: a fetched tree's deploy.sh entered the bootstrap again (rc=$rc)"

	# M: piped (BASH_SOURCE empty) from a directory that has manifests/, the run is still a bootstrap.
	mkdir -p "$T/stale/manifests"
	cat >"$T/run0.sh" <<EOS
set -euo pipefail
say() { printf '>> %s\n' "\$*"; }
die() { printf '!! %s\n' "\$*" >&2; exit 1; }
CONSOLE_TOKEN=""
STACK_ARGS=(--servers 1.2.3.4 --no-tunnel)
$lifted
$section0
echo "SECTION0 ROOT=\$ROOT"
EOS
	: >"$LOG"
	( cd "$T/stale" && env -u REF -u STACK_TAG -u INSTALL_FROM_MAIN -u STACK_TREE_VERIFIED -u STACK_TREE_UNSIGNED \
		PATH="$T/bin:$PATH" PIPED_LOG="$LOG" PIPED_FIX="$T/fix" PIPED_LATEST=v9.9.9 PIPED_EXPECT_ID="${SIGNER}v9.9.9" \
		bash -s <"$T/run0.sh" >"$T/out" 2>&1 )
	rc=$?
	{ [ "$rc" = 0 ] && grep -q '^TREE-RAN verified=v9.9.9' "$LOG" && ! grep -q 'using this checkout' "$T/out"; } \
		|| fail "M: piped from a directory with manifests/, the directory was taken for a checkout instead of the signed tree (rc=$rc): $(tail -n 2 "$T/out" | tr '\n' ' ')"

	mkrelease v9.9.7
	run L STACK_TAG=v9.9.7 PIPED_EXPECT_ID="${SIGNER}v9.9.7"
	{ [ "$rc" = 0 ] && grep -q '^TREE-RAN verified=v9.9.7' "$LOG" && ! grep -q '/releases/latest$' "$LOG"; } \
		|| fail "L: STACK_TAG=v9.9.7 did not run that tag's tree under its own identity, or asked /latest (rc=$rc)"
}

if [ "$bad" -gt 0 ]; then
	printf '%d problem(s). See CLAUDE.md invariant 94.\n' "$bad"
	exit 1
fi
echo "OK: a piped deploy runs only a release tree cosign verified for ${SIGNER}<tag>; main only with INSTALL_FROM_MAIN=1, unsigned and said so; fourteen behaviours run against a stub curl and cosign."
