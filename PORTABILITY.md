# The Hetzner baseline, and what to compare it against

Written 2026-07-25, from the cluster this repo actually brought up, so an AWS
and a GCP run can be compared line by line rather than by impression.

Everything in section 1 is measured. Everything in section 3 is a question with
a place to write the answer, not an answer.

---

## 1. What was measured here

### The cluster

| | |
|---|---|
| Provider / region | Hetzner Cloud, `fsn1` (Falkenstein) |
| Nodes | 5 x CPX42 (8 vCPU, 16 GB, 240 GB disk), Ubuntu 26.04 |
| Control plane | 3 servers, k3s embedded etcd (`--cluster-init` + 2 joins) |
| Workers | 2 agents |
| Kubernetes | k3s `v1.36.2+k3s1` (containerd 2.3.2-k3s2) |
| CNI | Calico `v3.29.1` via tigera-operator `v1.36.2`, pool `10.42.0.0/16`, `VXLANCrossSubnet` |
| Storage | Longhorn `v1.7.2`, 3 replicas; `stack-rwx` class for the RWX claim |
| Cloud controller | hcloud-cloud-controller-manager `v1.21.0`, `--controllers=service-lb-controller` only |
| Private network | one Hetzner network `10.10.0.0/16`, nodes on `10.10.0.2-6`, FREE |
| Node addressing | every node `--node-ip` on its private address; public IP only in `--tls-san` |

### Cost, as the provider's own API reports it

| Item | Price |
|---|---|
| CPX42 | about EUR 27.50/month each, hourly billed -> 5 nodes about **EUR 137/month** |
| Private network | EUR 0 |
| `lb11` load balancer | **EUR 7.49/month net** (EUR 8.99 gross), EUR 0.0120/hour, 20 TB traffic included |
| Longhorn volumes | EUR 0 beyond the node disks they live on (14 GB claimed of 5 x 240 GB) |
| Egress | 20 TB/month included per node |

Note for the comparison: the load balancer was the ONLY metered add-on this
deployment needed, and it was deleted after being proven. Everything else rides
on the nodes.

### What the workload looks like when it is up

- 6 pods: `genaryx-console`, `tokenfuse-cloud`, `tokenfuse-gateway`, `wardryx`,
  `idryx`, `policy-db`, spread one per node by a `preferred` podAntiAffinity
- 4 volumes: 1 RWX (5 Gi, shared event log, 3 replicas) + 3 RWO (2 Gi console
  state, 2 Gi money-plane snapshot, 5 Gi Postgres)
- 9 NetworkPolicies, default-deny in both directions, enforced by Calico
- 3 CronJobs (crypto trend, identity sweep, drills)
- images: `genaryx-console` 560 MB (141 MB content), `tokenfuse` 422 MB, the
  four Go planes 16-49 MB each

### Timings actually observed

| Step | Time |
|---|---|
| `tokenfuse` image build (Rust workspace, 2 binaries, cold) | about 3 min |
| `genaryx-console` image build (Rust + Node + Go + Python, cold) | about 8 min |
| `genaryx-console` rebuild after a one-file Rust change | about 2 min |
| `genaryx-console` rebuild after a frontend-only change | under 1 min |
| distributing 6 images to 5 nodes over the private network | about 2 min |
| Hetzner load balancer: created, attached to the network, services added | about 20 s |
| load balancer target health flip after the pod moved node | 15-45 s (15 s interval x 3 retries) |
| Longhorn RWO volume detach + reattach on another node | 30-60 s |
| seeding 34,678 call records through the cloud API | about 40 s |

### The proof that the deployment is real, not just green

Recorded in `evidence/`:

- `cluster-verified.md` - nodes, pod placement, volumes, every plane answering
- `loadbalancer-verified.md` - the balancer the CCM created, its targets, and
  the console answering through it from outside
- `freeze-test-verified.md` - Freeze clicked in the browser, the resulting
  `console-block:*` policy in wardryx, and the PDP denying the frozen agent
  while an untouched agent is still allowed

The dataset behind it: 9,288 runs, $4,254.67 settled spend, $3,022.43 governed
savings, 34,678 model calls, 180 incidents, 29 identities, 43 detector alerts,
7 policies, 5 pending approvals. Seeded with the campaign scripts in
`genaryx-a360/live-campaign/scripts` (`gx_fleet_v3.py`, `gx_policy_seed.py`,
`gx_idryx.py`), pointed at Service DNS instead of `127.0.0.1` and run from
inside the console pod, which is the only pod the NetworkPolicy lets reach the
planes.

---

## 2. What in this repo is cloud-specific, and what is not

Portable as written, on any conformant Kubernetes:

- `manifests/` - all of it except `50-loadbalancer.yaml`. The pod specs,
  NetworkPolicies, the RWX claim (by class NAME, not by provisioner), the
  environment descriptor, the Postgres store, the CronJobs.
- `images/` - all of it. Plain Docker builds, no registry, no cloud API.
- `build.sh` - imports images straight into each node's containerd over ssh.
  Works anywhere ssh works; irrelevant on a managed cluster where you would
  push to ECR/Artifact Registry instead.

Hetzner-specific, and therefore the interesting part of the comparison:

| Piece | What it does here | Where it will differ |
|---|---|---|
| `install.sh` node bootstrap | k3s installer over ssh, one flag list | EKS/GKE have no equivalent step; on EC2/GCE VMs it is nearly the same script |
| metadata service reads | `169.254.169.254/hetzner/v1/metadata/{instance-id,private-networks}`, no auth | AWS: IMDSv2 needs a PUT for a token first. GCP: `metadata.google.internal` with `Metadata-Flavor: Google` |
| `--kubelet-arg=provider-id=hcloud://<id>` | lets the CCM find the server (GOTCHAS 10) | `aws:///<az>/<instance-id>`, `gce://<project>/<zone>/<name>`. On EKS/GKE the managed control plane sets it, so this gotcha should vanish there and return on self-managed k3s |
| `--flannel-backend=none` + Calico | k3s's default CNI ignores NetworkPolicy (GOTCHAS 2) | EKS's VPC CNI does not enforce NetworkPolicy on its own either; GKE needs Dataplane V2 or `--enable-network-policy`. Same class of trap, different switch |
| Longhorn + `stack-rwx` | the RWX volume the whole multi-node design needs | AWS: EFS (EBS is RWO only). GCP: Filestore (PD is RWO). Both are METERED and Filestore has a large minimum capacity - this is likely the single biggest cost difference |
| hcloud CCM, LB-only | one narrow controller for `type=LoadBalancer` | AWS Load Balancer Controller (NLB/ALB, LCU-priced), GKE's built-in LB. Both charge per hour plus per capacity unit |
| private network `10.10.0.0/16` | free, and where all cluster traffic lives | VPC is free on both, but egress and NAT are not. A NAT gateway is a real line item |
| `iscsid` + `nfs-common` node prep | Longhorn's host-side requirements | EFS wants `amazon-efs-utils`; Filestore wants `nfs-common`. Managed node images differ |

Not cloud-specific but worth carrying into both runs, because they cost hours
here: GOTCHAS 8 (numeric image USER), 9 (loopback bind vs kubelet probes), 11
(default-deny drops the LB health check - the source address will be different
on each cloud, so the rule has to be re-derived, not copied), 12 and 14
(persistence for the money and policy planes), 15 and 16 (the console's frontend
mode and its environment descriptor).

---

## 3. The comparison sheet, AWS column filled in

Run on 2026-07-25, self-managed k3s on EC2. Evidence in
`cloud/aws/evidence/aws-run-verified.md`.

The GCP column has two kinds of entry, and they are marked apart on purpose.
Anything in **bold** was measured on a live cluster. Anything in _italics_ was
established at a desk on 2026-07-26 from Google's own price list, registry and
API, with nothing running and nothing spent. The rest is blank because it needs
more of the run.

**The GCP column is now from a FIVE-node cluster** (`c2d-highcpu-8`, AMD Milan,
the same silicon generation as CPX42), rebuilt after the first attempt.
The earlier three-node caveat below is kept because the first run is where most
of the findings came from.

**The first GCP cluster had THREE nodes, not five.** `CPUS_PER_VM_FAMILY` capped C3D at 24 vCPU in
`europe-west3` and the increase request was auto-denied on a fresh billing
account (GOTCHAS item 64), so the run went ahead at three servers, which is a
shape this repo supports: three etcd members, Longhorn's three replicas, the
whole workload. Every row about behaviour is comparable. Rows about timing are
not: three nodes means fewer images to distribute and one less join. A
five-node GCP column needs a second run on a family with room, and `c2d-highcpu-8`
is the one to use: AMD Milan, the same silicon generation as Hetzner CPX42, and
a ceiling of 100.

**Bring-up**

| | Hetzner | AWS | GCP |
|---|---|---|---|
| wall-clock, zero to "every plane answers" | about 25 min | **about 24 min** (33:47 the first time, three blocking bugs) | **28 min 44 s at 5 nodes**, second run, no stalls |
| steps needing a cloud-specific decision | baseline | **6** (see below) | **7**: the six found before the run, plus the WebAuthn origin |
| does `providerID` come out right unasked | no, set at install | **no, set at install**, and it carries the zone | **no, set at install**, and it carries project, zone and the NAME |
| is NetworkPolicy actually enforced | yes, Calico | **yes, Calico, unchanged** | **yes, Calico, 8 policies, default-deny verified** |
| infrastructure created by one command | no, servers by hand | **yes, 28 s for 3 nodes, 12 s for 2 more** | **yes, 14 resources, and it FAILED HALFWAY on an invisible quota** |
| did the cloud controller work first try | no (item 4) | **no (items 42, 43)** | **yes**, gce.conf and narrow RBAC derived from source |

**Storage**

| | Hetzner | AWS | GCP |
|---|---|---|---|
| does an RWX claim bind, which driver | yes, Longhorn | **yes, Longhorn, unchanged** | **yes, Longhorn, unchanged**, and the multipathd trap (item 60) did not fire because the fix was already in |
| minimum billable capacity for RWX | none | **none** (EFS has no minimum; not needed, Longhorn sufficed) | _1 TiB. Filestore BASIC_HDD bills a whole TiB at USD 0.19/GiB-month, so a 5 GiB claim costs USD 194.56/month against USD 1.80 on EFS_ |
| RWO detach/reattach when a pod moves | 30-60 s | not re-measured | |
| node disk | included in the server | **billed separately, USD 0.0952/GB-month** | _billed separately, USD 0.12/GiB-month, and it counts against the SSD quota_ |

**Load balancer**

| | Hetzner | AWS | GCP |
|---|---|---|---|
| does `type=LoadBalancer` get targets automatically | yes | **yes, all 5 instances** | **yes, all 5, and the right one goes healthy** |
| what source does the health check arrive with | the balancer's private address | **its own ENIs in the subnet, on a SEPARATE port kube-proxy answers** | _35.191.0.0/16 and 130.211.0.0/22, two published prefixes that belong to no VPC_ |
| how many annotations does the Service need | 6 | **5, sharing none of Hetzner's** | _0_ |
| does a healthy target mean traffic flows | yes | **NO. Healthy and silent for six minutes (item 45)** | **NO, and it never started: 40 minutes, two balancers, zero packets reaching the node (item 69, open)** |
| apply to a request returning 200 | about 1 min | **3 min 34 s** | **never, in this project** |
| hourly price | EUR 7.49/month | **USD 0.027/hour + LCU, about USD 19.71/month** | _USD 0.030/hour + USD 0.010/GiB, about USD 21.90/month_ |

**Cost, like for like, measured from each provider's own price list**

| | Hetzner | AWS | GCP |
|---|---|---|---|
| 5 x (8 vCPU / 16 GB) on demand, monthly | EUR 137 | **USD 1,710** (`c7a.2xlarge`, AMD) | **USD 1,410** (`c2d-highcpu-8`, AMD Milan, what actually ran) |
| cheapest AMD option, if quota allowed it | n/a | n/a | _USD 1,291_ (`c3d-highcpu-8`, capped at 24 vCPU here) |
| same, on the Intel part | n/a | **USD 1,487** (`c7i.2xlarge`) | _USD 1,465_ (`c3-highcpu-8`), and it needs a quota increase |
| node disks, 5 x 240 GB, monthly | included | **USD 114.24** | _USD 144.00_ |
| public IPv4, 5 addresses, monthly | included | **USD 18.25** | _USD 14.88, after 744 free IP-hours a month_ |
| private network | EUR 0 | **USD 0** (VPC), but cross-AZ traffic is USD 0.01/GB each way | _USD 0 (VPC), cross-zone traffic also billed_ |
| load balancer, monthly | EUR 7.49 | **USD 19.71** | _USD 21.90_ |
| RWX for a 5 GiB event log, monthly | EUR 0 (Longhorn) | **USD 1.80** (EFS) | _USD 194.56_ (Filestore, 1 TiB minimum) |
| egress | 20 TB per node included | 100 GB free, then about USD 0.09/GB | _no free allowance, USD 0.12/GiB to western Europe_ |
| **burn while running** | **about EUR 0.20/hour** | **USD 2.52/hour** | **USD 2.04/hour** (measured on what ran) |

**What the governance layer costs, measured**

**Read this table with one inequality in mind, because it is not a like-for-like
on silicon.** The AWS nodes were `c7a.2xlarge`, AMD EPYC **Genoa**; the GCP
nodes were `c2d-highcpu-8`, AMD EPYC **Milan**, one generation older. Same spec,
different chip, and that gap explains much of AWS's lead. It was not a choice:
`c3d` is GCP's Genoa part, its quota ceiling in this region was 24 vCPU against
the 40 needed, and the increase was auto-denied. The disks differed too, and
that one was an oversight: AWS ran 240 GB gp3 (a value left in the tfvars from
the July run) against GCP's 100 GB pd-balanced, which changes the hourly cost
and the disk's IOPS model but has little effect on a sequential audit append.

So: "what AWS gave us beat what GCP gave us" is supported. "AWS is faster than
GCP" is not, and a silicon-fair rematch would run `c7i` against `c3` (both
Intel, both available) or wait for a `c3d` quota.

| | Hetzner CPX42 (SHARED vCPU) | AWS c7a.2xlarge (dedicated, Genoa) | GCP c2d-highcpu-8 (dedicated, Milan) |
|---|---|---|---|
| peak decisions/s per pod | 2,344 | **4,028** (concurrency 16) | **2,479** (concurrency 32) |
| p50 at working rates | 3.9 ms | **1.9 ms** | **3.2 ms** |
| past 64 concurrent | **collapse to 1,059** | **no collapse, 3,782 at 256** | **no collapse, 2,353 at 256** |
| audit bytes per decision | 393 | **428** | **426** |
| freeze reaches traffic | 5 ms | **5.3 ms** | **5.0 ms** |
| cluster burn while measuring | EUR 0.20/h | USD 2.52/h (240 GB disks) | USD 2.04/h (100 GB disks) |
| decisions per currency-hour of cluster | 42.2 M per EUR | 5.7 M per USD | 4.4 M per USD |
| **cost per million governed decisions** | **EUR 0.024** | **USD 0.174** | **USD 0.229** |

**The collapse was the instance type, and now two clouds say so.** It was
written up from the Hetzner run as a design limit to plan against. CPX42 is a
SHARED vCPU instance; `c7a.2xlarge` and `c2d-highcpu-8` are not. On dedicated
cores, on two different hypervisors and two different AMD generations, the same
software holds its throughput all the way to 256 concurrent clients and only
latency grows, which is what a queue is supposed to do. The ceiling is real;
the cliff was the neighbours. That correction belongs in the article.

**Audit bytes per decision is a property of the software, not the cloud**: 426
and 428 on two clouds, from the same binary writing the same hash-chained
schema. The 393 from Hetzner differs because the payload did, not because the
cloud did.

**The last row is the one to lead with.** Governing an agent action costs
almost nothing in CPU, and what it costs is legible: about EUR 0.024 per
million decisions on Hetzner against USD 0.174 on AWS and USD 0.229 on GCP.
The hyperscalers land within a third of each other once the hourly rate is
divided by what the hour bought, and Hetzner is an order of magnitude below
both at half the throughput. That ordering survives the silicon caveat above;
the gap between the two hyperscalers does not.

**The same three proofs**

| | Hetzner | AWS | GCP |
|---|---|---|---|
| `cluster-verified` | 10 passed, 0 failed | **10 passed, 0 failed** | **10 passed, 0 failed** (9 without `--freeze`, as on AWS) |
| `loadbalancer-verified` | reproduced | **reproduced, after item 45** | **NOT reproduced**: address yes, traffic no (item 69) |
| `freeze-test-verified` | reproduced | **reproduced, survives a policy-plane restart** | **reproduced, survives a policy-plane restart** (block made through the admin API, not the browser) |
| `security-tests` | 23 passed, 1 noted | **22 passed, 0 failed, 2 noted** (the extra note is a missing `etcdctl`, encryption verified separately) | **24 passed, 0 failed, 2 noted** (the same two: no `etcdctl`, and the `default` namespace) |
| console reachable, operator signed in | yes | yes | **yes, and a passkey enrolled** after the origin fix |

**Teardown**

One command on AWS, `cloud/aws/teardown.sh`, but only because the hunt was done
first: the cloud controller creates the load balancer, so Terraform has never
heard of it, `destroy` fails on a DependencyViolation, and an orphaned NLB bills
USD 0.027/hour attached to nothing.

---

## 4. What the AWS run actually decided

**Six things needed a cloud-specific decision.** Five were predicted in section
2; the sixth was not, and it was the expensive one.

1. The metadata service needs a PUT for a token first.
2. `providerID` carries the zone: `aws:///<az>/<instance-id>`.
3. The firewall is a security group attached at launch, so the window in
   GOTCHAS item 19 never opens.
4. The cloud controller authenticates as the instance (better) and discovers
   nothing, so it must be told VPC, subnet, zone and cluster id (worse).
5. The load balancer object shares its `spec` with the Hetzner one and **not
   one of its annotations**.
6. **Unpredicted: EC2 discards pod traffic.** `SourceDestCheck` drops any
   packet whose source is not the interface's own, which is every pod packet
   once Calico decides not to encapsulate. And Calico decides that precisely
   because all five nodes share one subnet, which they do to avoid cross-AZ
   charges. The cost optimisation caused the outage. GOTCHAS item 44.

**One prediction in section 2 was wrong.** RWX storage was expected to be the
biggest cost difference. On AWS it is not: EFS has no minimum capacity, and
Longhorn worked unchanged so EFS was not needed at all. Whether it holds for
GCP Filestore, which does have a minimum, is the first thing to check there.

**The honest summary of portability.** Everything in `manifests/` applied to
AWS unchanged except `50-loadbalancer.yaml`, and `install-aws.sh` differs from
`install.sh` in five marked places out of about five hundred lines. The
workload is portable. The three things that touch the cloud (metadata,
load balancer, node networking) are not, and one of them fails in a way that
reports success.

**The cost headline.** Same machines, same workload, same proofs: **EUR 144.49
a month on Hetzner against about USD 1,862 a month on AWS**, roughly twelve
times, and that is before egress. Nothing in the run suggests AWS is worse
engineering; it suggests the two are priced for different questions.

---

## 5. Still open

- GCP, every row above that is not in italics: the run itself.
- ~~Filestore minimum billable capacity~~ **answered without creating anything,
  2026-07-26: 1 TiB on BASIC_HDD, USD 194.56/month for the 5 GiB event log,
  against USD 1.80 on EFS.** The section 2 prediction that RWX would be the
  biggest cost difference was wrong on AWS and is right on GCP, which is a
  better result than either answer alone: it means the prediction was about the
  wrong thing, not simply wrong. What varies is not "cloud RWX is dear" but
  whether the product bills provisioned or used capacity.
- Whether EKS removes items 2, 4 and 6 (it should remove all three) and what
  the USD 0.10/hour control plane fee is actually buying.
- RWO detach/reattach timing, not re-measured on AWS.
- The `tokenfuse` build being 73% slower on AWS while the console build is 32%
  faster, on identical vCPU and RAM. Worth one controlled measurement rather
  than the two guesses currently attached to it.
