# The AWS run, 2026-11-27: stack-k8s v1.19.0 and a clean stack-single v1.15.0

Command output from live machines, not claims about them. The logs beside this
file are the raw output with public addresses, the account id and the load
balancer name masked. Nothing else was edited.

## What ran

| | |
|---|---|
| stack-k8s | `v1.19.0` (1de88cf), `cloud/aws/deploy-aws.sh --trust-domain acme.example --run-budget-ceiling 1.00` |
| Cluster | AWS `eu-central-1a`, 5 x `c7i.2xlarge` (8 vCPU, 16 GiB, 100 GB gp3), 3 k3s servers + 2 agents, k3s `v1.36.2+k3s1`, Longhorn `v1.7.2` |
| Image that passed | Ubuntu 26.04 LTS `ami-0cd55f248a7e891a7` (build 20260722, the image of the 2026-07-25 run), pinned with `-var ami_id=` |
| Image that failed | Ubuntu 26.04.1 LTS `ami-05e5fa80bad7f28e0` (the current SSM image), kernel `7.0.0-1018-aws`, see finding 1 |
| stack-single | `v1.15.0`, the latest release, installed on a fresh `m7i.xlarge` (4 vCPU, 15 GiB, Ubuntu 26.04.1) in the same VPC |

## Results

| Proof | Result | Log |
|---|---|---|
| Deploy, zero to every plane answering, July image | 16 min 30 s (05:23:28Z to 05:39:58Z), images pulled by digest, nothing built | `deploy3.log` |
| `verify.sh` | 20 passed, 1 failed, 1 noted (the failure is finding 2) | `deploy3.log` |
| `security-tests.sh` | 28 passed, 0 failed, 6 noted | `deploy3.log` |
| `verify.sh --freeze` | 21 passed, 0 failed, 2 noted | `verify-freeze.log` |
| Load balancer from `manifests/50-loadbalancer.yaml` | address in 15 s, console HTTP 200 through it about 105 s later (DNS), 1 of 5 instances InService with `externalTrafficPolicy: Local` | `loadbalancer.log` |
| stack-single, bare VM to installed | 5 min 12 s including the cosign check; `Verified OK` against the release workflow identity, bootstrap identical to the signed tree, 70 checks ok, 0 failed | `stack-single-install.log` |
| `install.sh status` on that box | 62 ok, 0 failed, 18 containers up, exit 0 in 93 s | `stack-single-status.log` |
| Teardown | `teardown.sh --yes`: 21 resources destroyed, sweep "Nothing left"; then by direct query in `eu-central-1`: 0 instances, volumes, addresses, load balancers, non-default VPCs | `teardown.log` |
| Cost at the published rates | cluster 2.1272 USD/hour for about 54 minutes, the stack-single VM about 0.25 USD/hour for 11 minutes: about USD 2 in all | `cost-live.log` |

## Findings

1. **The current Ubuntu 26.04.1 image breaks the policy store.** On
   `ami-05e5fa80bad7f28e0` (kernel 7.0) AppArmor denies signals between
   processes inside a container: profile `cri-containerd.apparmor.d`, peer
   `cri-containerd.apparmor.d//&unconfined`, `operation="signal"`. Postgres
   cannot signal its own children (`pg_ctl: could not send stop signal:
   Permission denied`, `could not signal for checkpoint`), `policy-db-0` stays
   in recovery, and wardryx never becomes ready, so `deploy-aws.sh` stops at
   "wardryx did not roll out with its Keyryx signer". The same version on the
   July image does not hit it. Evidence: `failure-ami-20261127-pods.txt`,
   `failure-ami-20261127-apparmor.txt`. The fix belongs in the installers
   (a containerd or k3s that understands stacked AppArmor labels, or a profile
   for the store), followed by a run on the current image.
2. **`bus-owner` fails on the Longhorn RWX volume.** The Job mounts the events
   claim's root and gets `ls: /bus/streams: Remote I/O error` (EREMOTEIO, 121).
   On the node the NFS client returns the same error for the share root and
   for `streams/`, while `conform/`, `custody/` and `focus/` stat fine; in the
   share-manager the export is intact (`streams` 20000:10001, mode 2750). The
   planes, which mount `streams` by subPath, keep writing to it. The Job runs
   out of retries, so the first `verify.sh` counts it and `--freeze`, run after
   the Job's pod was removed, does not. Evidence: `bus-owner-rwx-evidence.txt`.
3. **The cloud controller made a Classic ELB, not an NLB**, from the same
   `50-loadbalancer.yaml`. It served the console and health-checked correctly;
   the 2026-07-25 sheet recorded an NLB, so the comparison rows need the type.

## Provider key

The provider key was handed to the gateway as a file (`--anthropic-key-file`),
with the run budget ceiling at 1.00.
