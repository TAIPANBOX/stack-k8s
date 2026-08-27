# Range 2, 2026-08-27: the run as it happened

Times UTC. Instances created by the operator's own `terraform apply` at ~17:57Z
after the first apply failed on GOTCHAS 87.

| time | event |
|---|---|
| ~17:57 | three instances RUNNING; the IAM role fails on the reserved id (GOTCHAS 87) |
| 18:00 | role id given a per-cluster nonce, `terraform apply` completes |
| 18:01:38 | `deploy-gcp.sh` starts, full run, no `--skip-*` |
| 18:02-18:03 | three k3s servers, **each with `--node-name` pinned** |
| 18:03:47 | Calico, all nodes Ready |
| ~18:04 | **`cluster DNS: more than one replica` -> `coredns replicas=2`**, on two different nodes |
| 18:05 | Longhorn, StorageClasses, cloud controller, kubeconfig |
| 18:06:45 | image build starts on the builder (the last node) |
| 18:19:01 | both images built and distributed to both other nodes |
| 18:19:0x | **the key-removal step runs and the deploy CONTINUES**, where range 1 died |
| 18:19:22 | independent check: all three nodes reachable, `authorized_keys` 600 ubuntu |
| 18:19:3x | step 3/5 workload; step 4/5 `verify.sh` **12/0**; step 5/5 `security-tests.sh` **27/0** |
| 18:21:50 | S1 baseline, 10 probes, all `403 deny` |
| 18:22:22 | S2 first attempt: PDP pod deleted. 45/45 denied and **proved nothing**, see the cache correction |
| 18:24:13 | probe fixed to vary the agent id, baseline re-taken, 6/6 `403 deny` |
| 18:24:40 | **S2: wardryx scaled to 0** |
| 18:25:06 | scaled back. 32/32 refused, 0 allowed, `failmode=Closed` in the gateway log throughout |
| 18:25:22 | last failmode line: ~16 s from scale-up to deciding again |
| 18:26:49 | **S3: server-2 stopped**, holding wardryx AND the policy store |
| 18:27:28 | gateway begins logging failmode; 38 lines over the window |
| 18:29:15 | 70/70 refused, 0 allowed |
| 18:29:35 | server-2 started |
| 18:30:22 | node **Ready** again, and **three node objects for three machines**: F3 held |
| 18:33:24 | policy plane actually deciding again: **182 s after Ready** |
| 18:34 | teardown |

## The correction that mattered

Scenario 2's first run was green and empty. `TOKENFUSE_WARDRYX_CACHE_TTL_MS` is
3000 and the probe repeated an identical request once a second, so the cache
answered. The tell was that every response carried a real verdict at a moment
when the decider was supposed to be gone. Worth stating because the same shape
has now appeared several times in two days: a check that passes without
exercising its subject looks exactly like a check that passes.
