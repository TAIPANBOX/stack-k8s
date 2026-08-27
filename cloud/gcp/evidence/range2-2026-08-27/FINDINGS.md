# GCP range 2, 2026-08-27: the stack under failure, and three fixes proven

Range 1 measured the platform and never reached the stack, because a defect in
our own deploy took the operator's ssh away. That defect is fixed, so this run
is the one range 1 could not do.

Three nodes, `c3d-highcpu-8`, europe-west3-a, from 17:57Z. Full deploy from bare
instances: **~18 minutes** (17:57 apply, 18:01:38 deploy start, 18:19 workload).

## The three fixes from #32, each verified on a live cluster

| fix | how it was proven | result |
|---|---|---|
| F1, the deploy takes its own ssh away | the deploy ran past the key-removal step, and I checked all three nodes independently | **all three reachable, `authorized_keys` mode 600 owner ubuntu** |
| F2, cluster DNS at one replica | the installer's own step, then the pod placement | **`replicas=2 ready=2`, on two different nodes** |
| F3, node identity re-decided at boot | **the exact operation that produced the ghost**: server-2 stopped for ~3 min and started | **3 node objects for 3 machines**, and server-2 kept its ORIGINAL creation timestamp 18:03:02, so the object was reused rather than recreated |

F3 is the one worth dwelling on. In range 1 the same stop/start produced a
fourth node object that sat NotReady for the rest of the cluster's life holding
17 pod records. Here it produced nothing. That moves the fix from "defensive,
untested" to measured, under the conditions that originally failed.

Both new `verify.sh` checks also ran and passed inside the deploy:

```
ok   no machine is registered under two node names
ok   cluster DNS has 2 ready replicas
```

## The suites the repository already ships

- `verify.sh`: **12 passed, 0 failed**, 1 noted (heraldyx not deployed)
- `security-tests.sh`: **27 passed, 0 failed**, 3 noted

Both run against a healthy cluster. That is the gap this range set out to fill.

## Does a refusal survive the plane underneath being broken?

The probe is `security-tests.sh` 11b reused verbatim: a `shell_exec` tool, which
the shipped policy forbids for `agent://mockryx.local/*`, sent from inside the
gateway pod to its own port. No model provider is reached, so repeating it is
free.

| # | what was broken | probes | allows | verdict |
|---|---|---|---|---|
| 1 | nothing | 10 | 0 | every one `403 deny` |
| 2 | wardryx scaled to **0** for 25 s | 32 | **0** | every one `403`, gateway log shows `applying failmode=Closed` throughout |
| 3 | the whole **machine** holding wardryx AND the policy store powered off | 70 | **0** | every one `403`, 38 failmode lines logged |

**No forbidden call was ever allowed**, under a dead decider, a dead machine, or
a restart. Fail-closed is not a configuration claim here, it is a measurement.

### And a correction I had to make mid-run

My first version of scenario 2 reported 45 of 45 denials and proved nothing. The
gateway carries `TOKENFUSE_WARDRYX_CACHE_TTL_MS=3000` and my probe sent an
IDENTICAL request once a second, so the cache answered most of them. The pod
also came back in about one second, so there may have been no gap to test at
all. The fixed probe varies the agent id per call, and scenario 2 was re-run
with wardryx scaled to zero for 25 seconds rather than deleted.

Green and meaningless is the failure mode this estate keeps meeting. It was
caught here by asking why every single answer carried a real verdict when the
decider was supposed to be gone.

## Findings

### R2-1. The response cannot tell a decision from a default

`x-fuse-wardryx: deny` is set identically whether wardryx returned a deny or
whether the gateway could not reach it and applied failmode. Both are safe, and
they are different facts: one means the policy was consulted, the other means it
could not be. The difference exists only in the gateway's own WARN log
(`applying failmode=Closed`), which no caller and no dashboard sees.

An operator watching responses during a total policy-plane outage sees exactly
what a healthy cluster looks like.

### R2-2. A node reporting Ready is about three minutes short of the plane working

Measured on the stop/start in scenario 3:

| event | time |
|---|---|
| server-2 stopped | 18:26:49 |
| server-2 started | 18:29:35 |
| node **Ready** | 18:30:22 |
| policy plane actually deciding again | **18:33:24** |

**182 seconds** between the cluster calling the node healthy and the decider
answering. Every call in that window was refused, correctly, by failmode. So the
cost of fail-closed is not theoretical: for three minutes after a node came back
green, no legitimate call could pass either. The allow-path probe returns `402`
when the policy plane is working and `403` when it is not, and it returned `403`
for the whole window.

The delay is the Longhorn volume detaching from a dead node and reattaching. The
`Ready` condition does not wait for it, and nothing else reports it.

### R2-3. The stack's own services report Running on a powered-off machine

Same shape as range 1's F5, but on our services rather than infrastructure pods.
With server-2 off, `kubectl get pods` listed `wardryx` and `policy-db-0` as
`Running` on it. That is the documented 300 s eviction toleration, and it means
the console and any dashboard show the policy decider as healthy while its
machine is switched off.

## What this run does NOT cover

- **One trial each.** The 182 s and the 38 failmode lines are what happened once.
- **No partition test at the network level.** Scenarios stopped at a killed pod
  and a killed machine; cutting the gateway from a LIVE wardryx by NetworkPolicy
  was planned and not run.
- **The identity plane was never stressed**, only the policy plane.
- **Storage was never deliberately broken**, though Longhorn's reattach time is
  what R2-2 measures, and one `remote I/O error` appeared on a rescheduled pod
  and cleared on retry.
- **R2-1 is a reading of behaviour, not of the source.** I did not read the
  gateway's header-setting code; I inferred it from the header being identical
  in both states.
