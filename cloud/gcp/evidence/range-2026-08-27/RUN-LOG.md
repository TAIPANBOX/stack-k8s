# GCP range 2026-08-27: the run as it happened

Times are UTC, from the machines themselves.

| time | event |
|---|---|
| 16:41:23 | billing starts, 3 x c3d-highcpu-8 + 300 GB pd-balanced, europe-west3-a, 1.1258 USD/h |
| 16:43-16:44 | three nodes register, etcd on all three |
| ~16:50 | image build runs on node 3, the last node, which `deploy-gcp.sh` picks as the builder |
| ~16:55 | the distribution-key cleanup rewrites `~/.ssh/authorized_keys` on nodes 1 and 2, and skips the builder |
| ~17:00 | deploy stops at step 3/5, `Permission denied (publickey)`; only 2 of ~10 images built |
| 17:00-17:05 | cause ruled out one by one: IP, key fingerprint, oslogin, serial console, metadata re-sync. Node 3 works, nodes 1 and 2 do not, and that is exactly the cleanup's skip list |
| 17:05:22 | observer armed on node 3 |
| 17:07:07 | last `Ready` for node 1 |
| 17:07:09 | `NotReady`, **2 s detection for a graceful stop** |
| 17:11:22 | 17 pods still reported `Running` on the powered-off machine |
| 17:11:56 | node 1 started again |
| 17:12:07 | replacement coredns starts on node 2, **298 s without cluster DNS** |
| 17:12:26 | node 1 rejoins under a NEW name; ghost object left behind |
| ~17:13 | SSH to node 1 works again, restored by the reboot alone |
| 17:15:48 | node 1 partitioned from both peers, self-lifting |
| 17:15:48-17:20:49 | node 1's own API times out on every probe, no stale reads |
| 17:16:33 | majority marks it `NotReady`, **45 s detection for a partition** |
| 17:20:49 | partition lifts on its own |
| 17:21:21 | nodes 2 and 3 reset together, node 3 with `node-name` pinned, node 2 without |
| 17:21:22 | node 1 alone: its API refuses within **1 s** |
| ~17:21:46 | peers back, both under their ORIGINAL names, and the unfixed control did not fail |
| ~17:24:20 | teardown |

## Scenarios from PLAN.md: what ran

Ran: node death, quorum under single loss, network partition, quorum loss at
2 of 3, node rejoin, DNS availability under node loss.

Did not run, and the reason is the same for all of them: the image build never
finished, so the services were not on the cluster. Anything about revocation,
erasure, delegation, PDP decisions or the record plane is untouched by this run.

## A gap in the evidence, and how it happened

The raw watch files from node 3 (`/tmp/watch.txt`, `/tmp/watch2.txt`) were lost
when that node was reset at 17:21:21, because `/tmp` does not survive a reboot
and I pulled the logs afterwards rather than before. The transitions they
recorded were already saved as excerpts in `evidence/06` and `evidence/16`, so
the findings stand on those, but the full series is gone.

Pull the logs before you reboot the machine that holds them.
