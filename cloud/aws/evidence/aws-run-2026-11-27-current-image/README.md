# The AWS run on the current Ubuntu image, 2026-11-27

The second run of that day. The first (`../aws-run-2026-11-27/`) proved v1.19.0 on the July image
and recorded that the current image broke the policy store (finding 1) and the bus owner
(finding 2). This run puts the fix for both in the installer and deploys on the image the SSM
parameter resolves today, with no `ami_id` pin.

The logs beside this file are command output from the live machines, with public addresses, the
account id and the load balancer host masked. Nothing else was edited. Times are UTC, which is
London time in November.

## What ran

| | |
|---|---|
| Tree | branch `fix/aws-ubuntu-26041-apparmor-rwx` on `885904a`, `cloud/aws/deploy-aws.sh --trust-domain acme.example --run-budget-ceiling 1.00 --anthropic-key-file <file>` |
| Image | `ami-0f4f39f350a940148`, `ubuntu-resolute-26.04-amd64-server-20261127` (Ubuntu 26.04.1 LTS), resolved from the SSM parameter at apply time |
| Kernel and AppArmor | `7.0.0-1018-aws`, apparmor `5.0.2-0ubuntu1~26.04.1`, `kernel.apparmor_restrict_unprivileged_unconfined=1` |
| Cluster | `eu-central-1a`, 5 x `c7i.2xlarge`, 3 k3s servers + 2 agents, k3s `v1.36.2+k3s1` (containerd `v2.3.2-k3s2`), Longhorn `v1.7.2` |

## Results

| Proof | Result | Log |
|---|---|---|
| The fix, on every node before k3s | containerd's profile as shipped: `denied`; with the stacked peer: `allowed`; `directory_delegations=N`, on 5 of 5 nodes | `deploy.log`, "host settings for the current kernel" |
| AppArmor while the stack runs | 64 container processes labelled `cri-containerd.apparmor.d//&unconfined (enforce)` across the 5 nodes, 0 denials under `cri-containerd.apparmor.d` since boot; the one denial per node is the installer's probe of the profile as shipped | `nodes-evidence.txt` |
| Postgres | `database system is ready to accept connections` from the entrypoint's server and again from PID 1 after its stop signal went through; `pg_is_in_recovery()` = `f` | `workload-evidence.txt` |
| The bus owner on the RWX volume | Job `bus-owner` succeeded on its first pod, `bus ready`, the full `streams/` listing | `workload-evidence.txt` |
| Deploy, zero to every plane answering | 11 min (07:15:56 to 07:26:56), images pulled by digest, nothing built | `deploy.log` |
| `security-tests.sh` | 28 passed, 0 failed, 6 noted | `deploy.log` |
| `verify.sh` inside the deploy | 20 passed, 1 failed: the old gateway pod of the ReplicaSet the run-budget patch had just replaced was still Terminating when the count ran; `verify.sh` now waits up to 90 s for such pods | `deploy.log` |
| `verify.sh`, with that wait, on the first server | 21 passed, 0 failed, 1 noted | `verify.log` |
| `verify.sh --freeze` | 21 passed, 0 failed, 2 noted | `verify-freeze.log` |
| Load balancer, `./loadbalancer.sh` (`loadbalancer-aws.yaml`, `aws-load-balancer-type: nlb`) | refused by the account: `OperationNotPermitted: This AWS account currently does not support creating load balancers` on every `CreateLoadBalancer` of ELBv2; nothing was created, the Service was deleted | `loadbalancer.log` |
| Teardown | `teardown.sh --yes`: 21 resources destroyed, sweep "Nothing left"; then by direct query in `eu-central-1`: 0 instances, volumes, elastic IPs, ELBv2 and Classic load balancers, non-default VPCs, snapshots | `teardown.log` |
| Cost at the published rate | the cluster from 07:14:22 (apply) to 07:38:00 (destroy complete), 23 min 38 s at USD 2.1272/hour: about USD 0.84; the gateway made no provider call (0 runs) | `apply.log`, `teardown.log` |
| The gate before the change | `scripts/nodes-fit-the-current-kernel.sh` on `885904a`: exit 1, no library | `gate-red-on-885904a.txt` |

## The three findings of the first run, closed

1. **AppArmor and the policy store** (GOTCHAS 169). On this kernel Ubuntu converts runc's change to
   the container profile into a stack, and containerd's default profile allowed signals only to
   the literal name. The upstream fix is containerd#14487 (merged 2026-11-16), in no containerd or
   k3s release yet. containerd loads its own profile only when none of that name is loaded, so every
   installer now loads containerd's profile with the two rules of #14487 first, from
   `lib/host-runtime.sh`, and keeps it in `/etc/apparmor.d` for every boot (invariant 98).
2. **The bus owner and EREMOTEIO** (GOTCHAS 170). A Linux 6.19+ NFS client asks for a directory
   delegation in its GETATTR, and the ganesha in Longhorn v1.7.2 answers `OP_ILLEGAL`, which the
   client turns into EREMOTEIO. The installers set the nfsv4 module's `directory_delegations=N`, now
   and in `/etc/modprobe.d`. The July image runs kernel 7.0 too, which is why the first run saw it
   there as well.
3. **Classic ELB instead of an NLB.** The first run applied `manifests/50-loadbalancer.yaml`, the
   Hetzner object, as `cloud/aws/README.md` then said to; it carries no AWS annotation, so the
   controller made a Classic Load Balancer. The README now sends the operator to `./loadbalancer.sh`,
   whose object asks for an NLB. On this account ELBv2 creation is refused by AWS itself until AWS
   Support enables it, so the NLB path stops at that refusal here; the annotation was on the
   Service (`loadbalancer.log`).
