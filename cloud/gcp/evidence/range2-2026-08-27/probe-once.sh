#!/usr/bin/env bash
# One forbidden-tool request, from inside the gateway pod to its own port.
# Prints: <utc time> <http status> <wardryx header or ->
#
# The agent id carries a UNIQUE suffix per call. Without it the gateway's
# TOKENFUSE_WARDRYX_CACHE_TTL_MS=3000 serves a repeated identical request from
# cache, and a once-a-second loop measures the cache rather than the decision
# path. The shipped policy forbids shell_exec for agent://mockryx.local/*, a
# wildcard, so every suffix is still a request that must be refused.
export KUBECONFIG="${KUBECONFIG:?}"
SUFFIX="${1:-$$}"
out="$(kubectl -n agent-stack exec -i deploy/tokenfuse-gateway -- env SUF="$SUFFIX" bash -s <<'IN' 2>/dev/null
body='{"model":"claude-haiku-4-5-20251001","max_tokens":8,"tools":[{"name":"shell_exec","description":"p","input_schema":{"type":"object"}}],"messages":[{"role":"user","content":"probe"}]}'
exec 3<>/dev/tcp/127.0.0.1/4100 2>/dev/null || { echo "NOCONN"; exit; }
printf 'POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nx-api-key: probe\r\nanthropic-version: 2023-06-01\r\ncontent-type: application/json\r\nx-fuse-run-id: range2-%s\r\nx-fuse-agent-id: agent://mockryx.local/probe-%s\r\nx-fuse-budget-usd: 5.0\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' "$SUF" "$SUF" "${#body}" "$body" >&3
timeout 8 cat <&3 2>/dev/null | tr -d '\r' | grep -iE '^HTTP/|^x-fuse-wardryx'
exec 3<&- 3>&-
IN
)"
code="$(printf '%s' "$out" | grep -o 'HTTP/1.1 [0-9]*' | awk '{print $2}' | head -1)"
verd="$(printf '%s' "$out" | grep -i '^x-fuse-wardryx' | awk '{print $2}' | head -1)"
printf '%s %s %s\n' "$(date -u +%H:%M:%S)" "${code:-NOANSWER}" "${verd:--}"
