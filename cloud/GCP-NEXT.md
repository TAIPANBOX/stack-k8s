# GCP, next

Hetzner is measured, AWS is measured, GCP is not. This is what the next person
needs so the run produces a comparison rather than an anecdote.

Written 2026-07-26, after the first end-to-end run by somebody other than the
author. Read `../GOTCHAS.md` items 56 to 63 before starting: every one of them
was found that day, and six were steps that worked the first time and were
impossible the second.

## What is already answered

`../PORTABILITY.md` holds the Hetzner baseline and the AWS column, both from
live clusters, plus what to measure. `cloud/aws/` holds the Terraform, the
installer differences and the evidence. GCP has none of that yet.

`cloud/COSTS.md` compares Hetzner against AWS from the providers' own price
lists. The GCP column is the first thing to fill in, and it can be filled in at
a desk: no cluster is needed to read a price list, and doing it first tells you
whether the deployment is worth its own cost.

## The shape of the work

`install.sh` is Hetzner-specific by design and says so: it reads
`169.254.169.254/hetzner/v1/metadata` for the private address and the server id.
`cloud/aws/install-aws.sh` is the same script with five marked `[AWS]`
differences. A `cloud/gcp/install-gcp.sh` should be the same again, and the five
places to look are:

1. the metadata service and the fields it answers with
2. the provider id the kubelet is given
3. the cloud controller, and pinning a version that EXISTS in the registry
   (item 42: a plausible version number is not a published one)
4. whatever GCP calls the thing that drops traffic between instances. On AWS it
   was `source_dest_check`, and finding it cost a day (item 44)
5. the firewall, scoped to the nodes you were GIVEN and not to every instance
   the credential can see (item 58)

## Traps that are not Hetzner's

These bit on both clouds and will bite again:

- **`multipathd` eats every Longhorn volume** (item 60). It arrives as a
  dependency of `open-iscsi`, which Longhorn needs, so it is present without
  anybody installing it. Every PVC stays Pending and the pod event blames the
  CSI driver.
- **The CCM deadlocks against itself** if the manifest is applied and then
  patched, because it is hostNetwork (item 57).
- **The installer must survive a second run.** That is now true and was not.
  Test it: run the whole thing twice on the same machine before believing it.

## The measurements that make it a comparison

Same numbers as the other two columns, or it is not one:

- PDP decisions per second per pod, and where it collapses
- audit bytes per decision
- how long a freeze takes to reach traffic
- monthly cost at the same shape, from the provider price list

## Before you start

Money: nothing here creates servers. They are yours, hourly billed, and the
scripts say so. Agree the spend before, not after.

Let's Encrypt allows five certificates per week for the same name, and a fresh
`caddy-data` volume issues one. Tearing the tunnel down and up repeatedly is not
free. Count with the CT log and count `entry_timestamp`, not `not_before`, which
is backdated about an hour (item 54).

The tunnel needs two names you control and two DNS records, and `deploy.sh` asks
for them before it installs anything. See `../tunnel/README.md`. Use names under
a domain the GCP operator owns, not ours: the check refuses ours on a cluster
that is not this one, which is the whole point of it.
