# Attacking our own cluster, 2026-07-25

Seven attacks, run against the live five-node cluster, each one either closed in
the code the same night or documented as a platform requirement. The point of
writing them down like this is that every "fixed" claim below has a measurement
next to it, and the two that are NOT fixed say so.

`security-tests.sh` re-runs the whole set: **23 passed, 0 failed, 1 noted.**

---

## 1. A pod that calls itself the console (GOTCHAS 20)

The NetworkPolicy admits `plane: console` to every plane. A pod assigns that
label to itself.

**Before the fix**

    attacker pod (label plane=console, no credentials of its own)
      REACHED wardryx:8090
      read 7 policies with the literal bearer 'devkey'
        found the freeze: console-block-agent-agent---meridian-example-treasury-reconciliation-batch
      DELETED policy console-block-agent-...-reconciliation-batch
      PDP now says: allow

An unprivileged workload removed a freeze with no console, no passkey and no
operator. Worse, the console went on displaying `FROZEN` with an `Unfreeze`
button while the PDP was answering `allow` (see
`../genaryx-shots/k8s-2026-07-25-security/01-attack-divergence-overview.png`,
and `02-attack-seen-in-bus.png` where `policy_updated action=delete` is followed
in the same second by `policy_allow`).

The one thing that did work: wardryx's hash-chained event log recorded the
deletion. Not invisible, but `decided_by: "default"` names an ORG, not a person,
because a shared devkey carries no identity.

**After the fix** (generated per-cluster keys, `WARDRYX_KEYS` set, `ALLOW_DEVKEY`
removed)

    the forged label still gets network reach to wardryx:8090
    does the attacker pod inherit any credential from the cluster? NO
    read policies    -> 401 Unauthorized
    delete a freeze  -> 401 Unauthorized
    read the fleet   -> 401 Unauthorized
    kill a run       -> 401 Unauthorized

## 2. Is a freeze enforced on the DATA PATH? (GOTCHAS 21, 22)

Before: no. The gateway's policy hook is off by default and reads
`TOKENFUSE_WARDRYX_URL`, not the `WARDRYX_URL` every other component uses. A
frozen agent's real traffic was never checked.

After wiring it (`mode=enforce`, viewer key, `failmode=closed`, timeout 250ms
against a measured p99 of 18.8ms), tested against the REAL provider with a
throwaway key:

| | frozen agent | untouched agent |
|---|---|---|
| HTTP | **403 in 20 ms** | **200 in 684 ms** |
| `x-fuse-wardryx` | `deny` | `allow` |
| provider | **never contacted** | answered: `'governed'` |
| usage | none | 14 in / 4 out, from Anthropic |
| billed | **$0.00** | **$0.000034** |

A second finding on the way: with `TOKENFUSE_UPSTREAM` unset the gateway does
not fail, it ANSWERS - `{"stub": true, "usage": {"input_tokens": 1000,
"output_tokens": 500}}`, metered at $0.0035. Fabricated answers and fabricated
spend, both plausible.

Time-to-effect of a freeze on live traffic: **5 ms**, one PDP round trip. Not the
3-second cache TTL, because wardryx marks a freeze's decisions `cacheable:
false` (the policy sets per-request dimensions), so they are never reused.

Budget enforcement, same path: a per-run budget below the call's cost returns
**402 "per-run budget exceeded"** before spending anything, and writes a
`breaker_tripped` event at `critical` into the hash-chained log.

## 3. Secrets in etcd (GOTCHAS 18)

    /registry/secrets/agent-stack/stack-policy-db
      dsn      postgres://wardryx:fb288c5a...@policy-db:5432/wardryx?sslmode=disable
      password fb288c5a4c2ee533954f9a0ff3b0d1372112266d550d8213

Read with `etcdctl get`, as ordinary text. After enabling encryption and
rewriting all 20 Secrets, the same query returns `k8s:enc:` and a canary Secret
is unfindable in the clear. `install.sh` now passes `--secrets-encryption` from
the first boot, which makes the whole retrofit unnecessary.

## 4. What the internet could reach (GOTCHAS 19)

                     22    6443   10250
    node1 (server)   OPEN  OPEN   OPEN
    node2 (server)   OPEN  OPEN   OPEN
    node3 (server)   OPEN  OPEN   OPEN
    node4 (agent)    OPEN   -     OPEN
    node5 (agent)    OPEN   -     OPEN

Both APIs answer `401` anonymously, so a scan looks clean; a world-reachable
kubelet is still one authorization bug from RCE on every node. After a Hetzner
cloud firewall (free, enforced outside the host): `10250` closed everywhere,
`22` and `6443` only from the operator's address, cluster unaffected because it
already runs on the private network.

## 5. The neighbouring namespace (GOTCHAS 23)

A privileged, hostPID pod with `/` mounted starts freely in `default`: that
namespace has no Pod Security label and no NetworkPolicy. Our containment held
from the outside:

    blocked  tokenfuse-cloud.agent-stack:8080
    blocked  wardryx.agent-stack:8090
    blocked  idryx.agent-stack:8081
    blocked  genaryx-console.agent-stack:7420
    blocked  policy-db.agent-stack:5432

because our policies key on label AND namespace. It also read no host secret -
but only because it ran as our image's uid 10001. A root image in that same
namespace would have owned the node. This is the platform's gap, not the
manifests', and it is the one item here that a client must close themselves.

## 6. Losing the node the policy store lives on

| t | what happened |
|---|---|
| +0s | node powered off, hard |
| +60s | node NotReady, **the freeze keeps being enforced** (`deny` on every 30s probe) |
| +5m | Kubernetes marks the pod for deletion; it stays `Terminating` forever |
| operator | `--force` (safe only because we know the node is dead) |
| +6m | Longhorn releases the RWO volume, Postgres restarts on another node |
| after | **7 policies restored from the store, PDP still `deny`** |

Enforcement never lapsed. The policy STORE does not self-heal: a StatefulSet
with an RWO volume deliberately refuses to double-attach. And the consequence of
`failmode=closed` is now measured too: had wardryx restarted during that window,
it would have failed to start and every call would have been denied. That is the
trade we chose, stated rather than discovered later.

## 7. Capacity, and what saturates first

| rate | achieved | p50 | p95 | p99 | errors |
|---|---|---|---|---|---|
| 10/min | 0.2/s | 4.1ms | 28.9ms | 28.9ms | 0 |
| 100/min | 1.7/s | 4.0ms | 4.6ms | 7.0ms | 0 |
| 1000/min | 16.6/s | 3.9ms | 4.5ms | 5.8ms | 0 |
| 8 workers, open loop | 1810/s | 3.9ms | 7.0ms | 9.4ms | 0 |
| 32 workers | 2230/s | 13.1ms | 23.3ms | 28.4ms | 0 |
| **64 workers** | **2344/s** | 21.7ms | 38.7ms | 47.5ms | 0 |
| 128 workers | 1059/s (collapse) | 43.0ms | 89.9ms | 114.7ms | 0 |

One wardryx pod on one CPX42: **~2,300 decisions/second**, about 138,000 a
minute. The demo's top rate of 1000 calls/minute is **0.7% of that**. Past ~64
concurrent callers throughput does not plateau, it degrades - design for
backpressure or replicas at that line, not for the peak number.

CPU is not the constraint: under and after load, wardryx sat at **1m CPU and
9 MiB**, the nodes at 2-4%. The constraint is the audit trail: every decision
writes **393 bytes** (11,249 events, 4.43 MB measured), so

- 1000 calls/minute -> ~550 MB/day -> the 5 GiB RWX claim lasts about 9 days
- at the 2,300/s ceiling the same claim fills in under 2 hours

Sizing rule: **~0.4 KB of audit per decision, so 1 GB per 2.5 million
decisions.** That, not the CPU, is what an enterprise deployment has to plan.
