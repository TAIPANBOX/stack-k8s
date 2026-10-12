# Closing a retained reservation, end to end, 2026-10-12

The first time a token minted by a real console was verified by a real gateway.
TokenFuse v1.9.0 serves the closure routes and genaryx-console v1.1.34 has the
close command; until this run each side had been tested only against a stub of
the other (genaryx invariant 22, tokenfuse invariant 89).

`evidence/closure-e2e/run.sh` re-runs the whole set from empty (`down -v`
first) on Docker, with the three published images and a stub provider:
**29 passed, 0 failed, twice.**

```sh
cd evidence/closure-e2e
TOKENFUSE_IMAGE=ghcr.io/taipanbox/tokenfuse:v1.9.0 \
TOKENFUSE_CLOUD_IMAGE=ghcr.io/taipanbox/tokenfuse-control-plane:v1.9.0 \
CONSOLE_IMAGE=ghcr.io/taipanbox/genaryx-console:v1.1.34 ./run.sh
```

Images, read with `docker buildx imagetools inspect` the same day:

| Image | Index digest |
|---|---|
| `tokenfuse:v1.9.0` (`tokenfuse v1.9.0 (95dc069)`) | `sha256:240ff0666e0a2602d9493d5d36a5774b974aa5f8d7505d37443cc452b4aca86d` |
| `tokenfuse-control-plane:v1.9.0` | `sha256:71bc880910c80b5ebe59188b58db51b30a7c53424ec9fc768a7d9001d5aa3b83` |
| `genaryx-console:v1.1.34` | built by this repository's tag v1.1.34 from genaryx `2317d80` |

## What it does

The stub provider takes the whole POST and closes the connection without a
status line, so the gateway cannot know whether the call was billed and keeps
its reservation (tokenfuse invariant 50). The operator signs in to the console
with a password set by `genaryx-web set-password` and, with no passkey
enrolled and `GENARYX_WEB_REQUIRE_PASSKEY` off, runs `money_close_retained` on
the session alone: the console's documented fallback (genaryx invariant 2).
The last case turns the requirement on and shows the command refused.

- **A, observed.** The console lists the retained call, closes it with an
  observed cost of 4321 micro-USD, and the gateway answers `closed: true`. The
  run's spend is exactly 0.004321 USD with nothing reserved, the gateway no
  longer lists it, and the control plane holds 4321 for the run, once. A
  second close of the same reservation is refused `already_closed` and charges
  nothing.
- **C, no charge.** Closed with `no_charge`: spend stays zero, nothing stays
  reserved.
- **D, the wrong secret.** A console holding a different 64-character secret
  mints a token the gateway refuses (`closure_token_invalid`, 401); the
  reservation stays retained.
- **E, a restart.** After `docker compose restart` of the gateway, the open
  reservation is still retained, the two closed ones are not, and the journal
  holds exactly one record: the startup rewrite dropped the closed ones.
- **B, passkey required.** With `GENARYX_WEB_REQUIRE_PASSKEY=1` (what both
  launchers set), the close is refused 403 `enrollment_required` before it
  reaches the gateway, and the reservation stays retained.
- **The record.** The console journaled four `close_retained` attempts (A
  twice, C, D; B is refused before dispatch), and the secret appears in no
  file under the console's state.

## The run

```
PASS  gateway answers /healthz
PASS  control plane answers
PASS  operator password is set in the console
PASS  operator signs in to the console
PASS  gateway logged that closing is on
      call through the gateway answered 502
PASS  A: the abandoned call is retained
PASS  A: the console lists it (viewer read)
      console close answered: 200 {"bus_error":null,"bus_recorded":true,"gateway_response":{"closed":true,"closed_at_millis":1791793004521,"evidence_kind":"observed","evidence_ref":"e2e invoice line 1","operation_id":"genaryx-73178ca6964c63a66d7a6d8e817aa591","replayed":false,"reservation_id":1,"revision":"527b2c823467af35","run_id"
PASS  A: the console closes it (200, closed true)
PASS  A: the gateway no longer lists it
PASS  A: run spent = 0.004321 USD (got 0.004321)
PASS  A: run reserved = 0 (got 0.0, retained amount was 394 uUSD)
      second close answered: 422 {"error":"already_closed","kind":"refused","message":"reservation 1 was already closed by operation genaryx-73178ca6964c63a66d7a6d8e817aa591","status":409}
PASS  A: a second close is not a second charge (spent still 0.004321)
PASS  A: the control plane holds the observed spend once (got 4321)
PASS  C: retained
PASS  C: the console closes it no-charge
PASS  C: the gateway no longer lists it
PASS  C: run spent = 0 (got 0.0)
PASS  C: run reserved = 0
PASS  D: retained
      wrong-secret close answered: 422 {"error":"closure_token_invalid","kind":"refused","message":"the closure token is not one this gateway accepts (signature, format, or a lifetime over 300 seconds)","status":401}
PASS  D: not closed
PASS  D: still listed by the gateway
PASS  E: after restart e2e-keep is still retained
PASS  E: after restart e2e-obs is not retained
PASS  E: after restart e2e-nc is not retained
PASS  E: the journal was rewritten to the one open record
      passkey-required close answered: 403 {"error":"this console requires a passkey for money_close_retained (GENARYX_WEB_REQUIRE_PASSKEY is on) and you have none enrolled: enrol one under Session > Passkeys, then run this again","webauthn":"
PASS  B: refused 403 enrollment_required
PASS  B: still listed by the gateway
      console journal lines mentioning close_retained: 4
PASS  record: every close attempt is journaled by the console (>= 4)
PASS  record: the secret appears in no console file
---
FAILS=0
```

## A person closes it with a passkey

The same compose file, the same three images, with
`GENARYX_WEB_REQUIRE_PASSKEY=1` (what both launchers set), on 2026-10-12. The
harness above shows only the refusal on that setting; this is the closure
itself, done by a person in a browser.

1. A call the stub provider abandoned left reservation 1 retained on run
   `passkey-accept` (394 micro-USD).
2. The operator signed in at `http://localhost:17420` with the password
   `set-password` had written, enrolled a passkey with Touch ID (the first
   passkey asks for the operator password as its factor), opened Money, and
   closed the reservation from "Close a retained reservation": `observed`,
   1000 micro-USD, reference `acceptance invoice line 1`, confirmed with
   Touch ID.

What each layer recorded:

- **The console:** `webauthn passkey enrolled user=op ... user_verified=true`,
  then `webauthn assertion verified user=op bound_to=money_close_retained`
  with the same credential and `user_verified=true`. Its journal line is
  `console.close_retained`, `decision: allow`, `http_status: 200`,
  `verify_result: closed`, `target: reservation:1`, on behalf of
  `user://local/op`, signed `sig_alg: webauthn-es256` with `sig_fpr` equal to
  the enrolled credential id: a passkey signature, not the software-signed
  fallback.
- **The gateway:** `retained reservation closed with evidence (D8)` for
  reservation 1 at revision `dc3de6cc44b62e0a`; `GET /v1/retained` empty; the
  run at `spent_usd: 0.001`, `reserved_usd: 0`, `retained: 0`.
- **The control plane:** `spent_microusd: 1000` for the run, one call.

## The checks can fail

Run once against `tokenfuse:v1.7.0` and `tokenfuse-control-plane:v1.5.0`,
which have no closure routes, with the same console: 19 failed, among them
every close and the retained listing itself. That run also found two faults
in the harness, both fixed before the green runs: a read-only secret file it
could not replace, and a "no longer listed" check that passed when the list
route itself answered 404 (it now requires an answer that is a list).

The first green attempt failed sign-in with 503 because the console reads
whether it has an operator only at startup (GOTCHAS 50); the harness now
restarts the console after `set-password`, as the deploy scripts here do.

## Console v1.1.36: the operator with no restart, 2026-10-12

Console v1.1.36 (genaryx#106) picks an operator set while it runs up at the
next sign-in, so the harness no longer restarts it after `set-password` and
checks three more things: the console answers, says it has no operator, and
then, still running, says it has one. `RESTART_AFTER_SET_PASSWORD=1` puts the
old restart back for an older image. On Docker Compose on the same Mac, with
`tokenfuse:v1.9.0` and `tokenfuse-control-plane:v1.9.0`:

- `genaryx-console:v1.1.35` (image label `dev.taipanbox.source.genaryx`
  `2317d80`): 16 failed. `set-password` succeeded, the running console still
  said it had no operator, and sign-in answered 503, so every close behind it
  failed. Parts B and D passed, because they recreate the console and a
  restarted console reads the operator at startup.
- `genaryx-console:v1.1.36` (label `41972c6`): 32 of 32, twice from empty.

The two green runs used ports 24100, 27420 and 28080 in a copy of this
directory, because another run held the default ports on the same machine at
the time; nothing else in the copy differed.

## Not proven

- **A cluster.** This is Docker Compose on one Mac (arm64), not these
  manifests; `closure/up.sh` and `closure/down.sh` were not run against an API
  server.
- **A live provider bill.** The provider is a stub, so the observed cost is a
  number the run chose, not one an invoice gave.
- **The passkey ceremony on a cluster.** It was done once by hand on Docker
  Compose (the section above); `run.sh` itself uses the no-passkey fallback
  and shows only the refusal, so a re-run does not repeat the ceremony.
- **The unit half.** No identity map was configured, so no unit reservation
  was retained or closed.
