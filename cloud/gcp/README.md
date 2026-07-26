# The same cluster, on GCP

Everything here exists so the Hetzner run of 2026-07-25 and the AWS run of the
same day can be repeated on GCP and compared line by line, using
`../PORTABILITY.md` section 3 as the sheet to fill in.

Read `../COSTS.md` first. The short version: **this cluster costs about USD
1.88 per hour**, nothing in this directory spends anything until `terraform
apply`, and `./teardown.sh` is the command that stops it.

## Who runs this, and on which machine

Whoever the project belongs to, or someone they have added to it, on their own
machine.

The firewall opens ssh and the Kubernetes API to **the address of the machine
running these commands**, so the operator and that address have to be the same
person. The teardown command is the kill switch for a bill that lands on the
project's billing account. And the ssh private key is generated locally by
`preflight.sh`, so it never has to be sent anywhere: a private key that arrives
over chat or a shared drive has stopped being private.

That machine stays light. Images are built **on a cluster node**, not locally,
so there is no Docker here, no source tree and no large checkout. What is needed
is `ssh`, `curl`, `terraform`, `gcloud` and `jq`, which is exactly what
`preflight.sh` checks.

---

## What has to be done by hand, and why

Three steps need a human, and on GCP they are noticeably lighter than the AWS
equivalents: **there is no access key to create, copy or store anywhere.**

### 1. A project, with billing linked

A DEDICATED project, not a shared one. On GCP the project is the blast radius
and the teardown boundary: `gcloud projects delete` removes everything in it at
once, which is a kill switch neither of the other two clouds has.

```bash
gcloud projects create stack-k8s-gcp
gcloud billing projects link stack-k8s-gcp --billing-account=<ACCOUNT_ID>
```

The billing account has to be a **full account, not a free trial**. A trial caps
a region at 8 vCPUs and refuses quota increases, and this cluster needs 40. The
upgrade keeps any trial credits and spends them first, but it also removes the
trial's automatic stop: past the credits, the card is charged. That is a real
change of posture and worth saying out loud before it happens.

### 2. Access for whoever drives the deployment

If that is the project's own owner, nothing to do. If it is someone else, they
are added as a principal on the project. Note that **the Owner role cannot be
granted from the command line** on a project with no organization: the API
answers `SOLO_MUST_INVITE_OWNERS`, and the console instead sends an email
invitation that has to be accepted. Roles that are not Owner have no such
ceremony:

```bash
gcloud projects add-iam-policy-binding stack-k8s-gcp \
  --member=user:someone@example.com --role=roles/editor
gcloud projects add-iam-policy-binding stack-k8s-gcp \
  --member=user:someone@example.com --role=roles/resourcemanager.projectIamAdmin
gcloud projects add-iam-policy-binding stack-k8s-gcp \
  --member=user:someone@example.com --role=roles/iam.serviceAccountUser
```

Editor covers the networks, machines and disks; `projectIamAdmin` is needed
because Terraform binds two roles to the service account the cloud controller
runs as; `serviceAccountUser` is needed to attach that service account to an
instance. Seeing the bill is a separate grant, on the billing account rather
than the project:

```bash
gcloud billing accounts add-iam-policy-binding <ACCOUNT_ID> \
  --member=user:someone@example.com --role=roles/billing.viewer
```

### 3. Two logins on this machine

```bash
gcloud auth login
gcloud auth application-default login
```

Two, and this is the most common way a first GCP run fails: `gcloud` uses the
first, **Terraform uses the second**, and having one without the other fails
inside the provider with a message about a missing token rather than a missing
login. `preflight.sh` checks both.

Nothing is typed into a file, nothing is pasted into a shell, and there is no
long-lived credential anywhere on disk. This is the whole substance of the
difference from `../aws/README.md` steps 2 and 3.

---

## What is in this directory

- **`preflight.sh`**: run it first. Checks the five tools and BOTH credentials,
  generates the ssh keypair if there is none, enables the two APIs, reads the
  region's real quotas against what this cluster needs, confirms the machine
  type and image exist, and writes `terraform.tfvars`. Creates nothing, spends
  nothing.
- **`deploy-gcp.sh`**: one command from bare instances to a tested stack.
  Cluster, sources, images, workload, and both proof suites.
- **Terraform**: `main.tf`, `variables.tf`, `outputs.tf`. A custom-mode VPC on
  `10.10.0.0/24` (the same range the other two used), one subnet in one zone,
  five instances, three tag-scoped firewall rules, and the service account the
  cloud controller runs as with two narrow role bindings.
- **The image**: Canonical's `ubuntu-2604-lts-amd64` family, resolved at apply
  time. Verified 2026-07-26 that it resolves to
  `ubuntu-2604-resolute-amd64-v20260723`, the same release the other two runs
  used.
- **`install-gcp.sh`**: `../../install.sh` with five GCP-specific differences
  marked `[GCP]` in the source and explained where they appear.
- **`teardown.sh`**: deletes the four objects the cloud controller made behind
  Terraform's back, then destroys, then re-checks that nothing is left billing.
- **`cost-live.sh`**: what the cluster is costing right now, from Google's own
  published rates. Free to run.
- **`loadbalancer-gcp.yaml`**: the one manifest that is not portable, and the
  shortest of the three.

---

## The run

### 0. Confirm the spend

```bash
cat ../COSTS.md
```

About USD 1.88/hour for the base cluster. Nothing has been spent yet.

### 1. Preflight (free)

```bash
cd cloud/gcp
./preflight.sh --project stack-k8s-gcp --enable-apis
```

It refuses to say "ready" until everything it needs is there, and it creates
nothing either way. The quota section is the one to read: on GCP a cluster that
cannot be created fails at `apply` with a quota message, and quota is per region
AND per machine family.

### 2. Plan (free)

```bash
terraform init
terraform plan
```

Creates nothing. It should show **14 resources** to add, and no load balancer
and no Filestore, because neither is on by default.

### 3. Apply (the meter starts here)

```bash
terraform apply
```

About 90 seconds. **Note the time**: that is when billing started. The output
ends with the exact `deploy-gcp.sh` line for step 4, with the addresses filled
in, and with the hourly rate it just started spending.

### 4. Everything else, one command

```bash
./deploy-gcp.sh \
  --servers "$(terraform output -json servers | jq -r 'join(",")')" \
  --agents  "$(terraform output -json agents  | jq -r 'join(",")')"
```

Add `--console-token <github-token>` if the Genaryx console is wanted. Without
it the open stack still deploys and still enforces, but there is no control
room, and the browser freeze proof cannot be reproduced.

Time it. "Wall-clock from zero to every plane answers" is the first row of the
comparison sheet: about 25 minutes on Hetzner, about 24 on AWS.

### 5. The third proof, and the load balancer

```bash
ssh -i ~/.ssh/stack-k8s-gcp ubuntu@<first server> \
  'sudo KUBECTL="/usr/local/bin/k3s kubectl" bash /root/stack-k8s/verify.sh --freeze'
```

Then the load balancer, a separate metered decision at USD 0.030/hour:

```bash
KUBECONFIG=kubeconfig.yaml kubectl apply -f loadbalancer-gcp.yaml
```

Watch for the two things the sheet asks about: whether the Service gets an
address without being told anything, and how long it takes before that address
actually carries traffic. On AWS the answer to the second was six minutes of a
healthy balancer serving nothing (GOTCHAS item 45), and the firewall here
already admits Google's probe ranges, so a failure at this point has a different
cause and is worth writing down.

### 6. A budget alert, so a forgotten cluster mails you

Free, two minutes, and it needs a role on the BILLING account rather than on the
project: Billing > Budgets & alerts > Create budget, USD 50, alerts at 50% and
100%.

### 7. Stop paying

```bash
./teardown.sh
```

It prints what it found, asks once, and re-checks afterwards. If it exits
non-zero, something is still billing and the message says what.

The nuclear option, which no other cloud in this comparison offers, is to delete
the project itself. That removes everything in it at once, billable or not, with
a 30 day undo:

```bash
gcloud projects delete stack-k8s-gcp
```

---

## What to write down while it runs

The rows in `../PORTABILITY.md` section 3, plus the six differences this
directory already found before a single instance existed. Those six are worth
stating in the article as "found while preparing", because they are the
difference between a cloud that is portable and a cloud that says it is:

1. **The metadata service wants a header.** Hetzner answers a plain GET. AWS
   wants a PUT for a session token first. GCE answers a GET carrying
   `Metadata-Flavor: Google`, and the header IS the authentication: it exists so
   that a browser or a confused proxy inside the VM cannot fetch metadata by
   accident, because a simple cross-origin request cannot set custom headers.
2. **`providerID` is readable.** `hcloud://<id>` and `aws:///<az>/<instance-id>`
   are opaque; `gce://<project>/<zone>/<name>` is the name the operator chose,
   and it is the same string the Node is registered under.
3. **The metadata service does not publish the subnetwork.** It publishes the
   network, the mac, the netmask and the gateway, but not the name of the
   subnet, while AWS publishes both `vpc-id` and `subnet-id`. The cloud
   controller needs that name, so it is the one value `install-gcp.sh` derives
   rather than reads.
4. **The firewall is scoped by tag.** Hetzner's `install.sh` has to call the
   provider API after boot; AWS attaches a security group at launch; GCP rules
   target a NETWORK TAG, so the rule reaches the nodes carrying it and nothing
   else in the project. That is GOTCHAS item 58 made structurally impossible.
5. **The load balancer needs no annotations at all.** Hetzner needed six, AWS
   needed five different ones, GCP needs none: everything comes from the
   `gce.conf` given to the cloud controller at install. The cost is that the
   manifest no longer explains the balancer.
6. **The AWS fix for a dropped pod network has no GCP counterpart, and this one
   is the finding.** On EC2 the answer was `source_dest_check = false`, one
   Terraform line, keeping the Kubernetes configuration byte-identical across
   clouds. A GCE VPC has no layer 2 at all: every packet is routed by
   destination, a pod address matches no route, and the packet is dropped before
   any anti-spoofing question is asked. `canIpForward` would let a node emit
   such a packet and nothing would deliver it; native routing would need one VPC
   route per node for a CIDR Calico allocates dynamically. So Calico moves to
   unconditional VXLAN, and **that is the only Kubernetes-level difference
   between the three clouds in this whole repository.**

And one prediction that is now half answered without creating anything.
`../PORTABILITY.md` guessed RWX storage would be the biggest cost difference. On
AWS that was **wrong**: EFS has no minimum and the 5 GiB event log costs USD
1.80/month. On GCP it looks **right**: Filestore BASIC_HDD has a 1 TiB minimum
at USD 0.19/GiB-month, so the same 5 GiB costs USD 194.56/month, 108 times the
AWS line. Longhorn is the primary path on all three and needs none of it, which
is what makes the comparison a choice rather than a constraint.
