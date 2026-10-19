# vouchryx's own keys and its first enrolled agent, minted once, for the default install. Sourced by
# deploy.sh, cloud/gcp/deploy-gcp.sh and cloud/aws/deploy-aws.sh, not run. CLAUDE.md invariant 24
# (amended 2026-10-19) and invariant 54.
#
# vouchryx runs agents-only in the default install: no identity provider, and so no trusted issuer.
# It refuses to start unless it has an upstream issuer OR at least one enrolled agent (its config:
# "VOUCHRYX_TRUSTED_ISSUERS is required (unless VOUCHRYX_AGENTS enrols at least one agent)"). So the
# default install enrols one agent, the operator's own, and writes its enrolment key to a file on this
# machine, 0600, the same shape as the agents' client key (agent-key). Two objects, minted here once:
#
#   Secret vouchryx-keys       signing.pem (the EC P-256 key vouchryx signs tokens with) and revoke_key
#                              (the bearer that POST /v1/revoke needs). Reused on every later run.
#   ConfigMap vouchryx-agents  the registry: one line, agent://<td>/agents/operator|agents|<org>|sha256:<digest>.
#                              It holds the digest of the enrolment key, never the key. Written only when
#                              absent: agent-tokens/up.sh replaces it when the operator enrols more agents.
#
# The enrolment key is written to $ROOT/agent-enrol-key (0600, gitignored). Its path is printed; the key
# is not.
#
#   . "$ROOT/lib/secret-doc.sh" || die "no lib/secret-doc.sh in $ROOT"
#   . "$ROOT/lib/vouchryx-mint.sh" || die "no lib/vouchryx-mint.sh in $ROOT"
#   vouchryx_mint_settle                 # after `apply -k`, before vouchryx is waited for
#
# Needs in scope, from the caller: die(), note() and k_ (its kubectl runner, given ONE string, as the
# deploy scripts' runner over ssh is), and ROOT. Every document goes to `kubectl create -f -` on stdin;
# nothing is applied, so `apply -k` cannot keep a second copy of a value in its annotation (invariant 60).
if ! declare -F die >/dev/null; then die() { printf '!! %s\n' "$*" >&2; exit 1; }; fi
if ! declare -F note >/dev/null; then note() { printf '   %s\n' "$*"; }; fi
VXM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
. "$VXM_ROOT/lib/gen.sh" || return 1

VXM_NS=agent-stack
VXM_TD_ORG=stack

vouchryx_mint_settle() {
  local tmp enrol digest td
  if k_ "-n $VXM_NS get secret vouchryx-keys -o name" >/dev/null 2>&1; then
    note "vouchryx-keys present: the signing key and the revoke key are kept"
  else
    tmp="$(mktemp -d)" || die "could not make a scratch directory for vouchryx's signing key"
    ( umask 077 && openssl ecparam -genkey -name prime256v1 -noout -out "$tmp/signing.pem" 2>/dev/null ) \
      || { rm -rf "$tmp"; die "could not mint vouchryx's EC P-256 signing key"; }
    local revoke
    revoke="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
      || { rm -rf "$tmp"; die "could not mint vouchryx's revoke key"; }
    # On stdin as a manifest (invariant 60): neither value is on a command line.
    secret_doc vouchryx-keys "signing.pem=@$tmp/signing.pem" "revoke_key=$revoke" \
      | k_ "-n $VXM_NS create -f -" >/dev/null \
      || { rm -rf "$tmp"; die "could not create Secret vouchryx-keys"; }
    rm -rf "$tmp"
    note "created Secret vouchryx-keys (signing.pem, revoke_key); neither value is printed"
  fi

  if k_ "-n $VXM_NS get configmap vouchryx-agents -o name" >/dev/null 2>&1; then
    note "ConfigMap vouchryx-agents present: the agent registry is kept"
    return 0
  fi
  # The trust domain as stack-wiring holds it (the deploy has set it before this runs).
  td="$(k_ "-n $VXM_NS get configmap stack-wiring -o jsonpath='{.data.TRAILRYX_TRUST_DOMAIN}'" 2>/dev/null)"
  [ -n "$td" ] && [ "$td" != "set-me.invalid" ] \
    || die "the trust domain is not set (stack-wiring TRAILRYX_TRUST_DOMAIN): vouchryx's first agent needs it. Nothing was written."
  enrol="$(gen 40)" || die "could not mint the operator agent's enrolment key"
  # sha256 of the key, with openssl so it works on the operator's machine and on a Linux node alike.
  digest="$(printf '%s' "$enrol" | openssl dgst -sha256 | awk '{print $NF}')"
  [ -n "$digest" ] || die "could not hash the enrolment key"
  ( umask 077 && printf '%s\n' "$enrol" > "$ROOT/agent-enrol-key" ) || die "could not write $ROOT/agent-enrol-key"
  printf 'agent://%s/agents/operator|agents|%s|sha256:%s\n' "$td" "$VXM_TD_ORG" "$digest" \
    | { printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: vouchryx-agents\n  namespace: %s\ndata:\n  agents: |\n' "$VXM_NS"; sed 's/^/    /'; } \
    | k_ "-n $VXM_NS create -f -" >/dev/null \
    || die "could not create ConfigMap vouchryx-agents"
  note "created ConfigMap vouchryx-agents with one enrolled agent (agent://$td/agents/operator); its enrolment key is in $ROOT/agent-enrol-key (0600, not printed)"
}
