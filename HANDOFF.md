# Where this is, and what to do next

Rewritten 2026-07-25 ~02:00, after the session that took the cluster from
"pods will not start" to a verified deployment. Everything below is verified
state, not intention.

## The cluster is up and the deployment is proven

Five Hetzner CPX42 in Falkenstein, private network `10.10.0.0/16`:

| Node | Public | Private | Role | providerID |
|---|---|---|---|---|
| ubuntu-16gb-fsn1-1 | 128.140.80.95 | 10.10.0.2 | k3s server, etcd | `k3s://` |
| ubuntu-16gb-fsn1-2 | 178.105.111.148 | 10.10.0.3 | k3s server, etcd | `k3s://` |
| ubuntu-16gb-fsn1-3 | 128.140.88.66 | 10.10.0.4 | k3s server, etcd | `k3s://` |
| ubuntu-16gb-fsn1-4 | 78.47.130.154 | 10.10.0.5 | agent | `hcloud://154920115` |
| ubuntu-16gb-fsn1-5 | 188.34.157.14 | 10.10.0.6 | agent, image build host | `hcloud://154920155` |

SSH as root with `~/.ssh/e02_hetzner_ed25519`. kubectl from node 1:
`ssh root@128.140.80.95 '/usr/local/bin/k3s kubectl ...'`. The hcloud token is
at `/root/.hcloud_token` on node 1, the k3s cluster token at `/root/.k3s_token`
on each node.

The MIXED providerIDs are deliberate, not a leftover: see GOTCHAS 10.
`install.sh` sets the right one on every node at install time; retrofitting a
SERVER would mean deleting its Node object, which also removes its etcd member.

One command re-checks all of it:

```bash
ssh root@128.140.80.95 'KUBECTL="/usr/local/bin/k3s kubectl" bash /root/stack-k8s/verify.sh --freeze'
```

Last run: **10 passed, 0 failed.**

## What was closed this session

1. **Pods green.** All six run, one per node, spread by a `preferred`
   podAntiAffinity (GOTCHAS 17). Every plane answers `/healthz`.
2. **The load balancer.** Diagnosed - the cloud controller silently SKIPS nodes
   whose providerID it does not recognise, so the balancer had a public IP and
   zero targets - fixed on the agents, and the console then served real traffic
   through it from the open internet. Evidence in
   `evidence/loadbalancer-verified.md`. Then **deleted**: a console on a raw
   public IP over plain HTTP is not the posture this product argues for, and it
   was the one metered add-on (EUR 7.49/month net, not the 5.39 previously
   written here). The Hetzner account now has zero load balancers.
3. **A fleet.** 9,288 runs, $4,254.67 settled spend, $3,022.43 governed
   savings, 34,678 calls, 180 incidents, 29 identities, 43 detector alerts, 7
   policies, 5 pending approvals, seeded with the campaign scripts from
   `genaryx-a360/live-campaign/scripts` pointed at Service DNS.
4. **The Freeze test that never happened.** Clicked in a browser: a confirm
   step, `FROZEN` on the card, a `console-block:*` policy in wardryx, the PDP
   denying that agent while an untouched one is still allowed, and the block
   still in force after both the console's and the policy plane's pods were
   restarted. `evidence/freeze-test-verified.md`.
5. **The gap that mattered most.** `install.sh` exists: node prep, k3s with the
   full flag list, Calico, Longhorn, the storage classes, the CCM patch, the
   generated policy-store credentials, the operator's kubeconfig. The bring-up
   no longer lives only in a chat transcript.
6. **Nine more traps found and fixed** (GOTCHAS 9-17), including three that
   were silent by nature: a money plane that reset itself on every restart, a
   policy plane that forgot every freeze on every restart, and a console that
   drew a fleet of invented `demo/*` agents when no environment descriptor was
   mounted.

## What is still open

1. **Screenshots.** The console was driven through a browser this session, but
   no PNG files were captured for the site's Platform page or the Tania
   materials. Reach it over an ssh tunnel to the node running its pod
   (GOTCHAS 13):

   ```bash
   ssh -L 17420:$(ssh root@128.140.80.95 '/usr/local/bin/k3s kubectl -n agent-stack get svc genaryx-console -o jsonpath={.spec.clusterIP}'):7420 root@<node running the console pod>
   ```

   The operator account is `ops`; its passphrase was generated into this
   session's scratchpad and is not stored in this repo. `genaryx-web
   set-password --username ops` inside the console pod sets a new one.
2. **The write-up.** `PORTABILITY.md` holds the measured baseline; the
   narrative for the site and for Tania is not written.
3. **One uncommitted change outside this repo**, verified, waiting on review:
   `genaryx-a360` (branch `feat/agent360-compare`),
   `crates/api/src/money/env.rs` now honours `TOKENFUSE_CLOUD_URL` in its env
   fallback, mirroring the policy plane's `WARDRYX_URL`. Two tests added,
   `cargo test -p genaryx-api --lib money::env` passes 9/9. The console image on
   the build host is built from it.
4. **Teardown.** Five CPX42 are about EUR 137/month. Yurii's call, and the AWS
   and GCP comparison runs may want this one alive to compare against.

## Next: the same thing on AWS and GCP

`PORTABILITY.md` is written for exactly that. Section 1 is the measured Hetzner
baseline (versions, costs, timings, dataset), section 2 marks every piece of
this repo that is Hetzner-specific and names its AWS/GCP counterpart, section 3
is the sheet to fill in. `verify.sh` speaks only kubectl, so the same proofs run
unchanged on EKS or GKE.

## The standing requirement, in Yurii's words

Every error we hit must be fixed IN THE CODE so a new user installing this
never meets it. `GOTCHAS.md` now has seventeen, each with the fix that is
already applied in these files.

## Related state outside this repo

- Genaryx PR #23 is MERGED into `main` (merge commit `9450e1d`).
- The Live Demo is public at https://it-rat.com/demo/.
- The old CPX62 box is destroyed. Nothing depends on it.
