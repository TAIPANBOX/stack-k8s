# Range 2, 2026-08-27: does a refusal survive the plane being broken?

Same three nodes, same rate (1.1258 USD/h). Instances from ~17:57Z.

Range 1 measured the PLATFORM under failure and never reached the stack, because
F1 stopped the deploy. F1 is fixed, so this run is about the thing range 1 could
not ask.

## What the repository already proves, so the hour is not spent on it

`security-tests.sh` has 13 sections and covers containment thoroughly, including
11b, which obtains one real ALLOW and one real DENY from the policy plane. All
of it runs against a HEALTHY cluster.

**Nothing anywhere asks what a refusal does while the plane underneath is
failing.** That is the gap, and it is the whole of this run.

## The probe

Reused verbatim from `security-tests.sh` 11b, so this is not a new mechanism
whose own correctness would be in question:

- inside the gateway pod, POST to its own port 4100
- `x-fuse-agent-id: agent://mockryx.local/sec-probe`
- a `shell_exec` tool, which the shipped policy forbids for that agent
- no model provider is reached, so repeating it costs nothing

## The scenarios, and the answer expected BEFORE each runs

| # | what is broken | expected | what would be a finding |
|---|---|---|---|
| 1 | nothing (baseline) | every response `403` with `x-fuse-wardryx: deny` | anything else means the run cannot judge the rest |
| 2 | the PDP pod is deleted under load | `403` throughout. Either a real `deny`, or a failmode `403` while it restarts | **any `200`**: a forbidden tool allowed because the decider was restarting |
| 3 | the node holding the PDP is stopped | `403` throughout | a `200`, or the gateway hanging without an answer |
| 4 | the gateway is cut from the PDP by NetworkPolicy | `403` from failmode=closed | a `200`, which would mean failmode is not closed in practice whatever the env says |
| 5 | a node is stopped and started | it rejoins under the SAME name, no second node object | a ghost node object, which is F3 unfixed |
| 6 | the deploy's key step, already run | ssh works to all three nodes | a `Permission denied (publickey)`, which is F1 unfixed |

Scenario 6 is not a separate run: the deploy now checks it itself, and either it
passed or the deploy stopped there.

## The distinction that matters in 2, 3 and 4

A `403` is not automatically a pass. `x-fuse-wardryx: deny` is a real verdict; a
`403` with no such header is failmode denying because it could not ask. Both are
safe, and they are not the same thing, so both are counted separately. A run
where every `403` came from failmode would mean the PDP was never consulted, and
that is worth knowing even though nothing was let through.

## The floor

`teardown.sh` at the end, and the sweep afterwards. GOTCHAS 87 is fixed, so the
next deploy after this teardown will not be blocked.
