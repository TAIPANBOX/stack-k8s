#!/usr/bin/env bash
# Withdraws the upstream identity provider that delegation/up.sh trusted, and the console's revoke wiring.
#
#   ./delegation/down.sh
#
# vouchryx itself stays. It is part of the default install and runs agents-only (CLAUDE.md invariant 24,
# amended 2026-10-19), and the agent tokens of invariant 54 do not depend on an identity provider. The
# gateway and the broker are not touched.
#
# The console is restored with its `$patch: delete` counterpart, never by re-applying the kustomization:
# `kubectl apply -k` does not remove a value a `kubectl patch --patch-file` added (GOTCHAS 113).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NS="${NS:-agent-stack}"
k() { kubectl -n "$NS" "$@"; }

echo "== restoring the console (its revoke wiring goes; the console runs as before)"
if k get deployment genaryx-console >/dev/null 2>&1; then
  k patch deployment genaryx-console --type strategic \
    --patch-file "$ROOT/manifests/54-delegation-console-unpatch.yaml" >/dev/null
fi

echo "== removing the trusted issuer (ConfigMap vouchryx-trusted-issuers)"
k delete configmap vouchryx-trusted-issuers --ignore-not-found=true >/dev/null

echo "== rolling vouchryx to forget it (it stays up, agents-only)"
k rollout restart deployment/vouchryx >/dev/null
k rollout status deployment/vouchryx --timeout=120s >/dev/null

echo "done. vouchryx trusts its enrolled agents only; the revoke key in the vouchryx-keys Secret is kept."
