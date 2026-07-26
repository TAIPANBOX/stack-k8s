# The AWS run, 2026-07-25

Command output from the live cluster, not claims about it. The same three
proofs the Hetzner run recorded in `../../evidence/`, reproduced on AWS so the
two can be compared line by line.

Raw output is in `raw-cluster.txt` beside this file.

## The cluster

| | |
|---|---|
| Provider / region | AWS, `eu-central-1a` (Frankfurt), single AZ |
| Nodes | 5 x `c7a.2xlarge` (8 vCPU AMD EPYC, 16 GiB, 240 GB gp3), Ubuntu 26.04 |
| Control plane | 3 servers, k3s embedded etcd, 2 agents |
| Kubernetes | k3s `v1.36.2+k3s1` |
| CNI | Calico `v3.29.1`, pool `10.42.0.0/16`, `VXLANCrossSubnet` |
| Storage | Longhorn `v1.7.2`, 3 replicas, `stack-rwx` for the RWX claim |
| Cloud controller | `cloud-provider-aws` **v1.35.2**, `--controllers=service` only |
| Network | one VPC `10.10.0.0/16`, one subnet `10.10.0.0/24`, no NAT gateway |

Everything above except the last three rows is identical to the Hetzner run.

## Proof 1: the cluster is running the stack

`verify.sh`: **9 passed, 0 failed**. With `--freeze`: **10 passed, 0 failed**,
matching Hetzner exactly.

```
ok   every node Ready
ok   every pod Running (finished Job pods ignored)
ok   workload spread over 5 nodes
ok   the RWX event volume is Bound
ok   1 default StorageClass
ok   8 NetworkPolicies present
ok   default-deny holds (the console cannot reach the policy store)
ok   all five planes answer 200
ok   an environment descriptor is mounted
```

`providerID` came out correct on all five nodes, `aws:///eu-central-1a/i-...`.
It is set at install time by `install-aws.sh`; nothing supplies it on a
self-managed cluster.

## Proof 2: the balancer is managed, not hand-made

`cloud/aws/loadbalancer.sh` created a Service, the cloud controller created a
real NLB, and all five instances registered as targets **automatically**. With
`externalTrafficPolicy: Local`, exactly one target went healthy (the node
running the console pod) and four went unhealthy, which is correct.

```
a9119e0f920784abba745aa6b4793fb5   network   internet-facing   active
i-0a5995f06812e5d51  31761  healthy
i-029bc36bb443ff2e4  31761  unhealthy     (no console pod, as intended)
... 3 more unhealthy
```

**The balancer reported healthy for six minutes while carrying no traffic at
all.** That is GOTCHAS item 45 and it is the most useful thing this run found:
the health check goes to a separate `healthCheckNodePort` that kube-proxy
answers on the host, so it never touches the pod and never tests any rule keyed
on source address. Both the security group and the NetworkPolicy were dropping
every real request.

Proven with a request rather than a status field, after the fix:

```
HTTP 200  http://a18d10d98be3c4e39b41b27fe205c1a9-...elb.eu-central-1.amazonaws.com/
```

`kubectl apply` to that 200: **3 min 34 s**.

## Proof 3: a frozen agent stays frozen

A `console-block:agent:<id>` deny-all policy written to wardryx, exactly as the
console writes it:

```
PUT /v1/policies/console-block-agent-...    200
PDP, frozen agent:   deny
PDP, control agent:  allow
```

Then the policy plane was deleted and rolled out again:

```
before restart, the PDP says: deny
restarting the policy plane...
ok   the freeze survived a policy-plane restart
```

**A note on how this test reads.** `verify.sh --freeze` does not create the
freeze; it checks that an existing one survives. Run against a cluster where
nobody has clicked Freeze, it reports `FAIL ... the block did not survive`,
which reads like the product losing state. It has not: there was nothing to
lose. The tell is the line above it, `before restart, the PDP says: allow`. The
first run here failed exactly that way and it was a missing precondition, not a
regression.

## Contained

`security-tests.sh`: **22 passed, 0 failed, 2 noted**, against Hetzner's 23
passed, 1 noted. The extra note is tooling, not posture:

```
note  could not read etcd (needs etcdctl on a server): encryption at rest UNVERIFIED
note  namespace default: Pod Security 'none', 0 NetworkPolicies
```

The Ubuntu AMI has no `etcdctl`, so the check could not look inside etcd.
Verified directly instead:

```
Encryption Status: Enabled
Active  Key Type  Name
 *      AES-CBC   aescbckey
```

The second note is the same one Hetzner reported (GOTCHAS item 23).

## Timings

| Step | AWS | Hetzner |
|---|---|---|
| `terraform apply`, 3 nodes from nothing | 28 s | no equivalent, servers made by hand |
| adding 2 more nodes | 12 s | no equivalent |
| apply to ssh answering on every node | 51 s | not measured |
| 5 nodes Ready with Calico | about 2.5 min | not measured |
| Longhorn ready on 5/5 | about 30 s | not measured |
| `tokenfuse` image, cold | **5 min 11 s** | about 3 min |
| `genaryx-console` image, cold | **5 min 25 s** | about 8 min |
| all six images | about 12.5 min | about 12 min |
| distributing 6 images to 5 nodes | about 2 min | about 2 min |
| load balancer to a request returning 200 | **3 min 34 s** | about 20 s + 15-45 s health flip |
| whole deploy, first time, 3 blocking bugs hit | 33 min 47 s | not comparable |
| whole deploy, with those fixes applied | about 24 min | about 25 min |

The build numbers are the interesting pair: **the same 8 vCPU and 16 GiB gives
the same total build time, and moves it between images.** The Rust workspace
was 73% slower here, the four-language console 32% faster. A single "AWS is
slower" or "AWS is faster" claim would not survive contact with this table.

Image sizes were reproducible across clouds: `tokenfuse` came out at 422 MB on
both. `genaryx-console` differs by 2 MB (562 vs 560) because this run built
from `origin/main` at `39034b2` rather than the same working tree.

## What it cost while running

Measured rates, AWS's own price list, `eu-central-1`:

| Item | USD/hour |
|---|---|
| 5 x `c7a.2xlarge` | 2.3426 |
| 5 x public IPv4 | 0.0250 |
| 1200 GB gp3 | 0.1565 |
| **base cluster** | **2.5241** |
| \+ NLB while published | 0.0270 |

The whole session, from `terraform apply` to `teardown.sh`, cost under USD 5.

---

## Second run, 2026-07-26: the governance layer measured

The 25 July run proved the deployment. This one existed for one number: whether
the throughput collapse past 64 concurrent clients, recorded on Hetzner and
written up as a design limit, is in the software or in the machine.

The cluster was rebuilt for it (`c7a.2xlarge`, five nodes, 25 min 29 s end to
end, `verify.sh` 9 passed 0 failed, `security-tests.sh` 24 passed 0 failed 2
noted) and destroyed immediately after the measurement. About 40 minutes of
cluster time.

```
concurrency    1:   1334.9 decisions/s   p50  0.72 ms   p95   0.79 ms
concurrency    8:   4015.9 decisions/s   p50  1.92 ms   p95   2.55 ms
concurrency   16:   4027.9 decisions/s   p50  3.76 ms   p95   5.73 ms
concurrency   32:   4003.0 decisions/s   p50  7.45 ms   p95  11.57 ms
concurrency   64:   3949.8 decisions/s   p50 14.69 ms   p95  23.98 ms
concurrency  128:   3883.3 decisions/s   p50 26.64 ms   p95  45.36 ms
concurrency  256:   3782.2 decisions/s   p50 30.96 ms   p95  64.97 ms
```

**No collapse.** Throughput holds within 6% from concurrency 8 to 256 and only
latency grows. GCP's dedicated-core run said the same thing on different
silicon and a different hypervisor. Hetzner's CPX42 is a SHARED vCPU instance
and lost more than half its throughput past 64. Two independent confirmations
are enough to correct the original conclusion: the ceiling is real, the cliff
was the neighbours.

Audit: 18,703 lines, 7,997,360 bytes, **427.6 bytes per decision**, which is 616
MB/day at 1000 calls a minute and fills the 5 GiB event volume in 8.7 days. GCP
measured 426.4 on the same binary. This number is the software's, not the
cloud's.

Freeze reaches traffic in **5.3 ms** (GCP 5.0, Hetzner 5).

**How the audit was measured, because the obvious way is wrong.** The event
volume is RWX, which Longhorn serves over NFS. In the console pod `ls -l`
reported 7,997,360 bytes while reading the same file returned ZERO lines: fresh
attributes, stale data pages. On GCP the skew ran the other way. The number
above was read from the node running `wardryx`, through the kubelet's own mount
of the volume, which is the writer's view and the only one that is true.
GOTCHAS item 70.
