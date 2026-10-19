#!/usr/bin/env bash
# Closure end-to-end: real tokenfuse gateway + control plane images, real
# genaryx console image. Usage:
#   TOKENFUSE_IMAGE=... TOKENFUSE_CLOUD_IMAGE=... CONSOLE_IMAGE=... ./run.sh
# Runs from empty (down -v first). Prints PASS/FAIL per check; exits 1 on any
# FAIL. Never prints a key or the closure secret.
set -u
cd "$(dirname "$0")"
: "${TOKENFUSE_IMAGE:?}" "${TOKENFUSE_CLOUD_IMAGE:?}" "${CONSOLE_IMAGE:?}"

GW=http://127.0.0.1:14100
CON=http://127.0.0.1:17420
CLOUD=http://127.0.0.1:18080
JAR=$(mktemp)
FAILS=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
check() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
dc() { docker compose --env-file .env "$@"; }

write_env() {
  {
    echo "TOKENFUSE_IMAGE=$TOKENFUSE_IMAGE"
    echo "TOKENFUSE_CLOUD_IMAGE=$TOKENFUSE_CLOUD_IMAGE"
    echo "CONSOLE_IMAGE=$CONSOLE_IMAGE"
    echo "GATEWAY_ADMIN=$GATEWAY_ADMIN"
    echo "CLOUD_ADMIN=$CLOUD_ADMIN"
    echo "CLOSURE_SECRET=$CLOSURE_SECRET"
    echo "REQUIRE_PASSKEY=${REQUIRE_PASSKEY:-}"
  } >.env
  chmod 600 .env
}

wait_http() { # url, tries
  for _ in $(seq 1 "${2:-60}"); do curl -fsS -m3 -o /dev/null "$1" && return 0; sleep 1; done
  return 1
}

console_login() {
  rm -f "$JAR"
  wait_http "$CON/api/auth/session" 60 || return 1
  curl -fsS -m10 -c "$JAR" -H 'content-type: application/json' \
    -d "{\"username\":\"op\",\"password\":\"$CONSOLE_PW\"}" "$CON/api/auth/login" >/dev/null
}

cmd() { # name, json body -> prints "STATUS BODY"
  curl -sS -m30 -b "$JAR" -H 'content-type: application/json' -w '\n%{http_code}' \
    -d "$2" "$CON/api/command/$1"
}

retain() { # run id -> makes one call the stub abandons
  curl -sS -m30 -o /dev/null -w '%{http_code}' "$GW/v1/messages" \
    -H 'content-type: application/json' -H 'x-api-key: e2e-not-a-key' \
    -H 'anthropic-version: 2023-06-01' -H "x-fuse-run-id: $1" -H 'x-fuse-budget-usd: 1' -H 'x-fuse-agent-id: agent://e2e.example/caller' \
    -d '{"model":"claude-haiku-4-5","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}'
}

bus_types() { docker run --rm -v closuree2e_events:/e:ro busybox:1.36 cat /e/tokenfuse.ndjson 2>/dev/null | jq -r --arg t "$1" 'select(.type == $t) | "\(.run_id) \(.agent_id) \(.severity)"'; }
bus_count() { bus_types "$1" | grep -c . || true; }
# The bearer goes to curl on stdin (CLAUDE.md invariant 60), never on its command line.
gw_retained() { printf 'header = "authorization: Bearer %s"\n' "$GATEWAY_ADMIN" | curl -fsS -m10 --config - "$GW/v1/retained"; }
gw_runs() { printf 'header = "authorization: Bearer %s"\n' "$GATEWAY_ADMIN" | curl -fsS -m10 --config - "$GW/v1/runs"; }
absent() { gw_retained | jq -e --arg r "$1" 'type == "array" and all(.[]; .run_id != $r)' >/dev/null; }
entry_for() { gw_retained | jq -c --arg r "$1" '[.[] | select(.run_id == $r)][0] // empty'; }
spent_of() { gw_runs | jq -r --arg r "$1" '.[] | select(.run_id == $r) | .spent_usd'; }
reserved_of() { gw_runs | jq -r --arg r "$1" '.[] | select(.run_id == $r) | .reserved_usd'; }

close_args() { # entry json, kind, amount|"" , ref
  local e=$1
  if [ "$2" = observed ]; then
    jq -cn --argjson e "$e" --arg ref "$4" --argjson amt "$3" \
      '{reservation_id: $e.reservation_id, expected_revision: $e.revision, evidence_kind: "observed", observed_microusd: $amt, evidence_ref: $ref}'
  else
    jq -cn --argjson e "$e" --arg ref "$4" \
      '{reservation_id: $e.reservation_id, expected_revision: $e.revision, evidence_kind: "no_charge", evidence_ref: $ref}'
  fi
}

# ---- setup -------------------------------------------------------------------
dc down -v --remove-orphans >/dev/null 2>&1
GATEWAY_ADMIN=$(openssl rand -hex 24)
CLOUD_ADMIN=$(openssl rand -hex 24)
CLOSURE_SECRET=$(openssl rand -hex 32)
CONSOLE_PW=$(openssl rand -hex 16)
REQUIRE_PASSKEY=""
mkdir -p closure
put_secret() { rm -f closure/secret; printf '%s' "$1" >closure/secret && chmod 0444 closure/secret; }
put_secret "$CLOSURE_SECRET"
write_env
dc up -d >/dev/null 2>&1 || { echo "compose up failed"; dc ps; exit 2; }
check "gateway answers /healthz" wait_http "$GW/healthz" 90
check "control plane answers" wait_http "$CLOUD/healthz" 60
set_pw() {
  wait_http "$CON/api/auth/session" 90 || return 1
  for _ in 1 2 3 4 5; do
    printf '%s\n' "$CONSOLE_PW" | dc exec -T console /usr/local/bin/genaryx-web set-password --username op >/dev/null 2>&1 \
      && return 0
    sleep 2
  done
  return 1
}
# A console from v1.1.36 picks an operator set while it runs up at the next
# sign-in (genaryx#106, GOTCHAS 50), so nothing is restarted here. For an older
# image set RESTART_AFTER_SET_PASSWORD=1, as the deploy scripts still do.
configured_is() { curl -fsS -m10 "$CON/api/auth/session" | jq -e --argjson v "$1" '.configured == $v' >/dev/null; }
check "console answers" wait_http "$CON/api/auth/session" 90
check "console says it has no operator before set-password" configured_is false
check "operator password is set in the console" set_pw
if [ "${RESTART_AFTER_SET_PASSWORD:-}" = 1 ]; then
  dc restart console >/dev/null 2>&1
else
  check "the running console says it has an operator, no restart" configured_is true
fi
check "operator signs in to the console" console_login
check "gateway logged that closing is on" sh -c "docker compose --env-file .env logs tokenfuse-gateway 2>&1 | grep -qi 'closure'"

# ---- A: an observed closure through the console ------------------------------
code=$(retain e2e-obs)
echo "      call through the gateway answered $code"
E=$(entry_for e2e-obs)
check "A: the abandoned call is retained" test -n "$E"
AMT=$(echo "${E:-null}" | jq -r '.amount_microusd // empty')
LIST=$(cmd money_list_retained '{}')
check "A: the console lists it (viewer read)" sh -c "printf '%s' \"\$1\" | head -n1 | grep -q '\"e2e-obs\"'" _ "$LIST"
R=$(cmd money_close_retained "$(close_args "$E" observed 4321 'e2e invoice line 1')")
echo "      console close answered: $(echo "$R" | tail -n1) $(echo "$R" | head -n1 | cut -c1-300)"
check "A: the console closes it (200, closed true)" sh -c "[ \"\$(printf '%s' \"\$1\" | tail -n1)\" = 200 ] && printf '%s' \"\$1\" | head -n1 | grep -q '\"closed\":true'" _ "$R"
check "A: the gateway no longer lists it" absent e2e-obs
S=$(spent_of e2e-obs); RV=$(reserved_of e2e-obs)
check "A: run spent = 0.004321 USD (got $S)" test "$S" = "0.004321"
check "A: run reserved = 0 (got $RV, retained amount was $AMT uUSD)" test "$RV" = "0" -o "$RV" = "0.0"
R2=$(cmd money_close_retained "$(close_args "$E" observed 4321 'e2e invoice line 1')")
echo "      second close answered: $(echo "$R2" | tail -n1) $(echo "$R2" | head -n1 | cut -c1-200)"
check "A: a second close is not a second charge (spent still 0.004321)" test "$(spent_of e2e-obs)" = "0.004321"
sleep 5
CS=$(printf 'header = "authorization: Bearer %s"\n' "$CLOUD_ADMIN" | curl -fsS -m10 --config - "$CLOUD/v1/runs" | jq -r '.[] | select(.run_id == "e2e-obs") | .spent_microusd')
check "A: the control plane holds the observed spend once (got $CS)" test "$CS" = "4321"

# ---- C: a no-charge closure --------------------------------------------------
retain e2e-nc >/dev/null
E=$(entry_for e2e-nc)
check "C: retained" test -n "$E"
R=$(cmd money_close_retained "$(close_args "$E" no_charge "" 'provider confirms no charge')")
check "C: the console closes it no-charge" sh -c "printf '%s' \"\$1\" | head -n1 | grep -q '\"closed\":true'" _ "$R"
check "C: the gateway no longer lists it" absent e2e-nc
check "C: run spent = 0 (got $(spent_of e2e-nc))" sh -c "[ \"\$(printf '%s' \"\$1\")\" = 0 ] || [ \"\$1\" = 0.0 ]" _ "$(spent_of e2e-nc)"
check "C: run reserved = 0" sh -c "[ \"\$1\" = 0 ] || [ \"\$1\" = 0.0 ]" _ "$(reserved_of e2e-nc)"

# ---- the bus: what the gateway wrote so far (tokenfuse 1.10.0, D10) ------------
check "bus: one call_retained per retained call so far (2)" test "$(bus_count call_retained)" = 2
check "bus: one retained_closed per applied closure (2)" test "$(bus_count retained_closed)" = 2
check "bus: call_retained is medium and names the calling agent" test "$(bus_types call_retained | grep -v -c ' agent://e2e.example/caller medium$')" = 0
check "bus: retained_closed is high and names the calling agent" test "$(bus_types retained_closed | grep -v -c ' agent://e2e.example/caller high$')" = 0
check "bus: the second, refused close of e2e-obs wrote no retained_closed" test "$(bus_types retained_closed | grep -c '^e2e-obs ')" = 1

# ---- D: a console holding another secret is refused by the gateway ------------
retain e2e-keep >/dev/null
E=$(entry_for e2e-keep)
check "D: retained" test -n "$E"
put_secret "$(openssl rand -hex 32)"
dc up -d --force-recreate console >/dev/null 2>&1
console_login || fail "D: sign-in after recreate"
R=$(cmd money_close_retained "$(close_args "$E" observed 1 'wrong secret attempt')")
echo "      wrong-secret close answered: $(echo "$R" | tail -n1) $(echo "$R" | head -n1 | cut -c1-300)"
check "D: not closed" sh -c "! printf '%s' \"\$1\" | head -n1 | grep -q '\"closed\":true'" _ "$R"
check "D: still listed by the gateway" test -n "$(entry_for e2e-keep)"
put_secret "$CLOSURE_SECRET"

# ---- E: a restart keeps the open one and forgets the closed ones -------------
dc restart tokenfuse-gateway >/dev/null 2>&1
wait_http "$GW/healthz" 60
check "E: after restart e2e-keep is still retained" test -n "$(entry_for e2e-keep)"
check "E: after restart e2e-obs is not retained" absent e2e-obs
check "E: after restart e2e-nc is not retained" absent e2e-nc
J=$(dc exec -T tokenfuse-gateway cat /var/lib/stack/traces/gateway/retained-reservations.ndjson 2>/dev/null)
check "E: the journal was rewritten to the one open record" test "$(printf '%s\n' "$J" | grep -c .)" = 1
check "bus: the restart's replay wrote no second call_retained (still 3)" test "$(bus_count call_retained)" = 3
check "bus: the refused closures (wrong secret) wrote no retained_closed (still 2)" test "$(bus_count retained_closed)" = 2

# ---- B: the launcher posture, passkey required --------------------------------
REQUIRE_PASSKEY=1
write_env
dc up -d --force-recreate console >/dev/null 2>&1
console_login || fail "B: sign-in after recreate"
E=$(entry_for e2e-keep)
R=$(cmd money_close_retained "$(close_args "$E" observed 1 'no passkey')")
echo "      passkey-required close answered: $(echo "$R" | tail -n1) $(echo "$R" | head -n1 | cut -c1-200)"
check "B: refused 403 enrollment_required" sh -c "[ \"\$(printf '%s' \"\$1\" | tail -n1)\" = 403 ] && printf '%s' \"\$1\" | grep -q enrollment_required" _ "$R"
check "B: still listed by the gateway" test -n "$(entry_for e2e-keep)"

# ---- the record --------------------------------------------------------------
CJ=$(dc exec -T console sh -c 'cat /var/lib/stack/events/console.ndjson 2>/dev/null; find / -name console.ndjson -not -path "/proc/*" 2>/dev/null' )
N=$(printf '%s\n' "$CJ" | grep -c 'close_retained' || true)
echo "      console journal lines mentioning close_retained: $N"
check "record: every close attempt is journaled by the console (>= 4)" test "$N" -ge 4
# the value comes in on stdin, read by the container's shell; it is in no argv
LEAK=$(printf '%s\n' "$CLOSURE_SECRET" | dc exec -T console sh -c 'read -r S; grep -rl -F "$S" /var/lib/stack 2>/dev/null | head -3')
check "record: the secret appears in no console file" test -z "$LEAK"

# ---- the mail: heraldyx reads the same bus once ------------------------------
rm -rf mail && mkdir -p mail
dc --profile mail run --rm heraldyx-once >/dev/null 2>&1
MAIL=$(cat mail/mail.txt 2>/dev/null)
check "mail: heraldyx wrote mail from this bus" test -n "$MAIL"
check "mail: a retained call is described, not the fallback" sh -c "printf '%s' \"\$1\" | grep -q 'sent and never answered'" _ "$MAIL"
check "mail: a closure is described" sh -c "printf '%s' \"\$1\" | grep -q 'closed by a person'" _ "$MAIL"
check "mail: no evidence reference reaches the mail" sh -c "! printf '%s' \"\$1\" | grep -q -e 'e2e invoice line' -e 'provider confirms no charge'" _ "$MAIL"
check "mail: no event is mailed with the fallback wording" sh -c "! printf '%s' \"\$1\" | grep -q 'does not have a description'" _ "$MAIL"

rm -f "$JAR"
echo "---"
echo "FAILS=$FAILS"
[ "$FAILS" -eq 0 ]
