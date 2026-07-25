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

## 3. The comparison sheet to fill in tomorrow

Same workload, same proofs, three clouds. For each of AWS and GCP, in both
shapes worth testing (self-managed k3s on VMs, and the managed service):

**Bring-up**
- [ ] wall-clock from zero to "every plane answers"
- [ ] how many steps needed a cloud-specific decision rather than a manifest
- [ ] does `providerID` come out right without being told (managed) or not (k3s)
- [ ] is NetworkPolicy actually enforced, and what had to be turned on

**Storage**
- [ ] does an RWX claim bind, with which driver, and how long does it take
- [ ] minimum billable capacity for RWX (this is where Filestore may hurt)
- [ ] RWO detach/reattach time when a pod moves node

**Load balancer**
- [ ] does a `type=LoadBalancer` Service get targets automatically
- [ ] what source address does its health check arrive with (rewrite GOTCHAS 11)
- [ ] hourly + per-capacity price, and what it costs to delete

**Cost, like for like**
- [ ] 5 x (8 vCPU / 16 GB) on-demand, monthly
- [ ] the same with 1-year commitment / savings plan, monthly
- [ ] RWX storage, monthly, at 5 Gi and at the minimum billable size
- [ ] load balancer, monthly
- [ ] egress for a demo's worth of traffic
- [ ] TOTAL vs **EUR 137/month + EUR 7.49 load balancer** measured here

**The same three proofs**
- [ ] `evidence/cluster-verified.md` reproduced
- [ ] `evidence/loadbalancer-verified.md` reproduced
- [ ] `evidence/freeze-test-verified.md` reproduced, including that the freeze
      survives a restart of the policy plane

**Teardown**
- [ ] one command, or a hunt for orphaned resources (load balancers, volumes,
      snapshots, NAT gateways, and any IP that keeps billing after the cluster
      is gone)
