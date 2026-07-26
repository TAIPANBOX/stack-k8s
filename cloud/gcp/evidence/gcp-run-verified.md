# The GCP run, 2026-07-26

Command output from the live cluster, not claims about it. The same three
proofs the Hetzner run recorded in `../../evidence/` and the AWS run recorded in
`../aws/evidence/`, reproduced on GCP so the three can be compared line by line.

Raw output is in `raw-cluster.txt` beside this file.

This is the SECOND cluster of the day. The first was three nodes, because a
quota ceiling refused the other two (GOTCHAS item 64), and it was torn down and
rebuilt at five once the machine family was changed to one with room. The
rebuild is the more valuable of the two runs: it is the one that found the traps
a first run cannot see.

## The cluster

| | |
|---|---|
| Provider / region | GCP, `europe-west3-a` (Frankfurt), single zone |
| Nodes | 5 x `c2d-highcpu-8` (8 vCPU AMD EPYC Milan, 16 GiB, 100 GB pd-balanced), Ubuntu 26.04 |
| Control plane | 3 servers, k3s embedded etcd, 2 agents |
| Kubernetes | k3s `v1.36.2+k3s1` |
| CNI | Calico `v3.29.1`, pool `10.42.0.0/16`, **`VXLAN` unconditional** |
| Storage | Longhorn `v1.7.2`, 3 replicas, `stack-rwx` for the RWX claim |
| Cloud controller | `cloud-provider-gcp` **v36.2.4**, `--controllers=service` only |
| Network | one custom VPC, one subnet `10.10.0.0/24`, no NAT gateway, firewall by network tag |
| Burn | USD 2.0387 / hour, from Google's own price list |

Two rows differ from both other runs and both are findings rather than
preferences.

**The CNI.** Hetzner and AWS run `VXLANCrossSubnet`, which sends raw pod
addresses between nodes that share a subnet. On AWS that produced a dropped pod
network fixed with one Terraform line (`source_dest_check = false`). A GCE VPC
has no layer 2 at all: every packet is routed by destination, a pod address
matches no route, and no instance flag changes that. So the encapsulation moves
into Calico, and this is the ONLY Kubernetes-level difference between the three
clouds in this repository.

**The machine family.** `c3d-highcpu-8` was the first choice: same spec, same
AMD generation as Hetzner CPX42, and the cheapest of the three candidates. It
was abandoned because `CPUS_PER_VM_FAMILY` capped C3D at 24 vCPU in this region
and the increase request was auto-denied in three seconds. `c2d-highcpu-8` is
AMD Milan, which is the SAME generation as CPX42 rather than one newer, so the
comparison arguably improved. It costs 9% more per hour.

## Proof 1: the cluster is running the stack

`verify.sh`: **9 passed, 0 failed**. With `--freeze`: **10 passed, 0 failed**,
matching Hetzner and AWS exactly.

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
ok   the freeze survived a policy-plane restart
```

The RWX line is worth its own sentence: Longhorn bound a `ReadWriteMany` claim
on GCP with no change to the manifests and no cloud storage product involved.
Filestore, which is what a GCP-idiomatic deployment would reach for, would have
cost USD 194.56/month at its 1 TiB minimum for a 5 GiB event log.

## Proof 2: the freeze survives a restart of the policy plane

The precondition is a block that somebody made. Nobody had clicked Freeze on
this cluster, so one was created through the same admin API the console's button
uses:

```
PUT /v1/policies/console-block:verify   -> 200
PDP now says: deny | tool "ledger_read" is denied by policy "console-block:verify"
```

then the policy plane was destroyed and rebuilt:

```
before restart, the PDP says: deny
restarting the policy plane...
ok   the freeze survived a policy-plane restart
```

**This check used to lie**, and the fix is part of this run. Run against a
cluster where nothing is frozen, it reported `the block did not survive`, naming
a persistence bug (GOTCHAS 14) that had not happened. It now says what is
actually true: nothing is frozen, so there is nothing for a restart to lose.

## Proof 3: the stack is contained

`security-tests.sh`: **24 passed, 0 failed, 2 noted**.

Against Hetzner's 23 passed / 1 noted and AWS's 22 passed / 0 failed / 2 noted.
The two notes are the same two AWS reported:

```
note could not read etcd (needs etcdctl on a server): encryption at rest UNVERIFIED
note namespace default: Pod Security 'none', 0 NetworkPolicies
```

The first is a missing tool on the node rather than a finding; `--secrets-encryption`
is set at install and verifiable separately. The second is about a namespace
this deployment does not use.

Two checks worth quoting in full, because they are the ones that make the
"governed" claim mean something:

```
10. a forged pod label buys nothing without a credential
    reach=yes  inherited_credential=no  read_policies=401  delete_freeze=401  read_fleet=401
    ok   the forged pod inherits no credential from the cluster
    ok   every admin verb from the forged pod was refused

11. the policy plane is on the data path, not only on the console
    ok   the gateway asks the PDP on every call (mode=enforce)
    ok   an unreachable PDP denies (failmode=closed)
```

## Not run

- **The load balancer.** `loadbalancer-gcp.yaml` was not applied, so the row
  about whether a `type=LoadBalancer` Service gets an address unasked, and how
  long before it carries traffic, is still open on GCP. It is a separate metered
  decision at USD 0.030/hour.
- **The browser freeze.** The block above was made through the API. Clicking
  Freeze in the console and watching the PDP change its mind is the same
  mechanism with a human in it, and it needs somebody at the browser.
- **Seeded campaign data.** This cluster governs an empty fleet. The Hetzner
  evidence was recorded against 9,288 runs and 34,678 model calls, which is what
  makes the console's numbers worth looking at.

## Timing

| | |
|---|---|
| `terraform apply`, 14 resources | about 30 s, plus a failed first attempt on quota |
| `deploy-gcp.sh` end to end, 5 nodes | **28 min 44 s** |
| of which the console image (four languages) | about 12 min |

The AWS run was about 24 minutes for the same shape, Hetzner about 25. The
difference here is almost entirely image build time on a different CPU
generation, not deployment behaviour.

## What this run cost in bugs

Seven, all found by running rather than reading, all fixed in the same session,
and four of them impossible to see on a first run:

1. `CPUS_PER_VM_FAMILY`, invisible in the obvious API, failed the apply halfway
2. Terraform outputs sliced by requested counts, so the partial apply could not
   be destroyed
3. GCE reports RUNNING before the ssh key is installed
4. k3s registers a GCE node under its full internal name, stalling each join 200 s
5. Recycled public addresses against a stale `known_hosts` refused every node on
   the rebuild
6. `CPUS_ALL_REGIONS`, a third and global vCPU ceiling, failed the apply again
7. `sudo umask 077; cat > file` writes the file unprivileged and 0644, so a key
   the script promised to protect was briefly world-readable on the node

The cost report and the teardown sweep each had a bug of their own: one exited
before printing its total when an API was disabled, the other reported the
project's own default firewall rules as this cluster's leftovers.
