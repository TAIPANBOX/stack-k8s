#!/usr/bin/env bash
# The MIRROR of probe-once.sh: a request the policy ALLOWS, with a budget too
# small for any call. On a healthy cluster the PDP says allow and the ledger
# then says 402, so 402 IS a positive verdict and nothing reaches a provider.
# Under failmode=closed this becomes 403, which is the price of failing closed.
export KUBECONFIG="${KUBECONFIG:?}"
SUFFIX="${1:-$$}"
out="$(kubectl -n agent-stack exec -i deploy/tokenfuse-gateway -- env SUF="$SUFFIX" bash -s <<'IN' 2>/dev/null
body='{"model":"claude-haiku-4-5-20251001","max_tokens":8,"messages":[{"role":"user","content":"probe"}]}'
exec 3<>/dev/tcp/127.0.0.1/4100 2>/dev/null || { echo "NOCONN"; exit; }
printf 'POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nx-api-key: probe\r\nanthropic-version: 2023-06-01\r\ncontent-type: application/json\r\nx-fuse-run-id: range2a-%s\r\nx-fuse-agent-id: agent://mockryx.local/allow-%s\r\nx-fuse-budget-usd: 0.0000001\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' "$SUF" "$SUF" "${#body}" "$body" >&3
timeout 8 cat <&3 2>/dev/null | tr -d '\r' | grep -iE '^HTTP/|^x-fuse-wardryx'
exec 3<&- 3>&-
IN
)"
code="$(printf '%s' "$out" | grep -o 'HTTP/1.1 [0-9]*' | awk '{print $2}' | head -1)"
printf '%s %s\n' "$(date -u +%H:%M:%S)" "${code:-NOANSWER}"
