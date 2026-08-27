# The hour, and what each minute is for

`@yurii 2026-08-27`: "робиш годину, проганяєш, але робиш прогони максимальної
кількості тестів - від розгортання до різних блокувань, до падіння сервісів".

Three nodes, `c3d-highcpu-8`, `europe-west3`. **1.1258 USD/hour**, measured by
`terraform plan`, not estimated. One hour is 1.13 USD. Three rather than one
because a single node cannot fail over: node death, partition and quorum are
exactly the class he asked for, and they cost the same hour.

## What already exists, so the hour is not spent rebuilding it

`deploy-gcp.sh` runs five steps and two suites: `verify.sh` (402 lines, "it is
running") and `security-tests.sh` (626 lines, "it is contained"). Deployment and
blocking are therefore ALREADY covered by the repository, and re-writing them
would be the most expensive way to learn nothing.

What is NOT covered, and what this hour adds:

## The measurements, in the order they run

Each is ten minutes at most and several are seconds. The rule he set: measure a
short window and extrapolate, do not collect masses of data.

| # | what | why it needs a cloud | node cost |
|---|---|---|---|
| 1 | deployment itself, timed | `verify.sh` says whether, never how long | 3 |
| 2 | `security-tests.sh` | the containment proof, re-run on today's code | 3 |
| 3 | a v1 segment read after a REAL restart | today's proof was a file read; this is a process boot | 1 |
| 4 | payload erasure, proof survives | the whole reason `RECORD_V2` exists | 1 |
| 5 | request-path cost of the revocation check | wardryx claims 3.2 ms p50; the check is new | 1 |
| 6 | pod kill under load | does a refusal become an allow while it restarts | 3 |
| 7 | node death under load | 04.08: death is noticed LESS than partition | 3 |
| 8 | network partition, 90 s | 04.08 found this worse than death; re-check with the new plane | 3 |
| 9 | vouchryx unreachable mid-flight | fail-closed was proved at startup and at the poll, never at a partition | 3 |
| 10 | strict identity on a real agent loop | `enforce` is the default since today, and it reaches doors it did not | 3 |

## What is written down before anything runs

- the clock: apply time, teardown time, and the hourly rate, so the bill is
  arithmetic rather than a surprise;
- for every scenario, the ANSWER EXPECTED before it runs, so a result that
  merely looks plausible cannot be read as a pass;
- every command and its output, into `evidence/`.

## The floor

`teardown.sh` when the hour is up, and it checks afterwards that nothing is
still billing. Leaving it up is a decision, not a default: on 2026-08-04 it was
left running deliberately and the memory records the burn rate for that reason.
