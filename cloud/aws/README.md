# The same cluster, on AWS

Everything here exists so the Hetzner run of 2026-07-25 can be repeated on AWS
and compared line by line, using `../PORTABILITY.md` section 3 as the sheet to
fill in.

Read `../COSTS.md` first. The short version: **this cluster costs about USD
2.13 per hour**, nothing in this directory spends anything until `terraform
apply`, and `./teardown.sh` is the command that stops it.

## Who runs this, and on which machine

Whoever owns the AWS account, on their own machine. Not a shared one, and not
someone else's.

Three reasons, all of them practical rather than procedural. The security group
opens ssh and the Kubernetes API to **the address of the machine running these
commands**, so the operator and that address have to be the same person. The
teardown command is the kill switch for a bill that lands on the account
owner. And the ssh private key is generated locally by `preflight.sh`, so it
never has to be sent anywhere: a private key that arrives over chat or a shared
drive has stopped being private.

That machine stays light. Images are built **on a cluster node**, not locally,
so there is no Docker here, no source tree, and no large checkout. What is
needed is `ssh`, `curl`, `terraform`, `aws` and `jq`, which is exactly what
`preflight.sh` checks.

---

## What has to be done by hand, and why

Three steps need a human. They are first because everything else is blocked on
them, and they take about five minutes.

### 1. An AWS account with billing set up

If there is already one, skip to step 2. If not, it is created at
<https://portal.aws.amazon.com/billing/signup>, needs a card, and the identity
check can take anywhere from two minutes to a few hours. Worth starting before
anything else if the account does not exist yet.

### 2. A dedicated IAM user for this run

In the console, **IAM > Users > Create user**:

- Name: `stack-k8s-deploy`
- Do **not** give it console access. It only ever speaks to the API.
- Permissions: **Attach policies directly > Create policy > JSON**, and paste
  [`iam-policy.json`](iam-policy.json). Name it `stack-k8s-deploy`.
- Then **Security credentials > Create access key > Command Line Interface**.

That policy is narrow on purpose: pinned to `eu-central-1`, allowed to pass
exactly one IAM role to exactly one service, and given no ability to read data,
create users, or change billing. It is not a substitute for an admin account,
it is a blast radius.

### 3. Put the key on this machine

```bash
aws configure --profile stack-k8s
```

Four answers: the access key id, the secret, `eu-central-1`, `json`.

Type the secret yourself. It should not be pasted into a chat, a file in this
repo, or a shell command that lands in history. Then:

```bash
export AWS_PROFILE=stack-k8s
aws sts get-caller-identity
```

If that prints the account id, everything below works.

---

## What is in this directory

- **`preflight.sh`**: run it first. Checks the five tools, generates the ssh
  keypair if there is none, verifies the AWS credentials, finds your public
  address and writes `terraform.tfvars`. Creates nothing, spends nothing.
- **`deploy-aws.sh`**: one command from bare instances to a tested stack.
  Cluster, sources, images, workload, and both proof suites.
- **Terraform**: `main.tf`, `variables.tf`, `outputs.tf`. A VPC on
  `10.10.0.0/16` (the same range the Hetzner private network used), one subnet
  in one AZ, five instances, a security group that mirrors the Hetzner cloud
  firewall, and the IAM role the cloud controller needs.
- **The AMI**: resolved at apply time from Canonical's public SSM parameter.
  Verified 2026-07-25 that Ubuntu 26.04 LTS, the release the Hetzner nodes ran,
  is published for `eu-central-1` (`ami-0cd55f248a7e891a7`, built 2026-07-22).
- **`install-aws.sh`**: `../../install.sh` with the five AWS-specific
  differences marked `[AWS]` in the source and explained where they appear.
- **`teardown.sh`**: deletes the load balancer the cloud controller made behind
  Terraform's back, then destroys, then re-checks that nothing is left billing.
- **`cost-live.sh`**: what the cluster is costing right now, from AWS's own
  published rates. Free to run.

---

## The run

### 0. Confirm the spend

```bash
cat ../COSTS.md
```

About USD 2.13/hour for the base cluster, USD 2.16 with the load balancer and
EFS on. Nothing has been spent yet.

### 1. Preflight (free)

```bash
export AWS_PROFILE=stack-k8s
cd cloud/aws
./preflight.sh
```

It checks the tools, makes the ssh key if there is none, confirms the
credentials work, and writes `terraform.tfvars` with your public address. It
refuses to say "ready" until everything it needs is there, and it creates
nothing either way.

### 2. Plan (free)

```bash
terraform init
terraform plan
```

Creates nothing. It should show about 20 resources to add, and no load
balancer, no NAT gateway and no EFS, because none of those are on by default.

### 3. Apply (the meter starts here)

```bash
terraform apply
```

About 90 seconds. **Note the time**: that is when billing started. The output
ends with the exact `deploy-aws.sh` line for step 4, with the addresses filled
in.

### 4. Everything else, one command

```bash
./deploy-aws.sh \
  --servers "$(terraform output -json servers | jq -r 'join(",")')" \
  --agents  "$(terraform output -json agents  | jq -r 'join(",")')"
```

Add `--console-token <github-token>` if the Genaryx console is wanted. Without
it the open stack still deploys and still enforces, but there is no control
room, and the browser freeze proof cannot be reproduced.

This does five things: the cluster (`install-aws.sh`), the sources and images
built **on a node** rather than locally, the manifests, `verify.sh` and
`security-tests.sh`. On Hetzner the equivalent took about 25 minutes end to
end, most of it the four-language console image. Time it here, because
"wall-clock from zero to every plane answers" is the first row of the
comparison sheet.

### 5. The third proof, and the load balancer

`deploy-aws.sh` already ran two of the three proofs. The freeze test is the
third, and it needs the console:

```bash
ssh -i ~/.ssh/stack-k8s-aws ubuntu@<first server> \
  'sudo KUBECTL="/usr/local/bin/k3s kubectl" bash /root/stack-k8s/verify.sh --freeze'
```

Then the load balancer, which is a separate metered decision at USD
0.027/hour:

```bash
# from cloud/aws, with the local kubectl:
KUBECONFIG=kubeconfig.yaml kubectl apply -f ../../manifests/50-loadbalancer.yaml

# or without a local kubectl, straight on the first server:
ssh -i ~/.ssh/stack-k8s-aws ubuntu@<first server> \
  'sudo /usr/local/bin/k3s kubectl apply -f /root/stack-k8s/manifests/50-loadbalancer.yaml'
```

Watch for the two things the sheet asks about: whether the Service gets an
address without being told anything, and what source address the health check
arrives with. On Hetzner that second one was GOTCHAS item 11 and it cost an
hour. Here the security group already admits the subnet CIDR, so if the health
check still fails, the reason is different and worth writing down.

### 6. A budget alarm, so a forgotten cluster mails you

Free, and worth the two minutes. Console: **Billing > Budgets > Create budget >
Cost budget**, USD 50 monthly, alerts at 50% and 100% to your address. AWS
Budgets is free for the first two budgets.

### 7. Stop paying

```bash
./teardown.sh
```

It prints what it found, asks once, and re-checks afterwards. If it exits
non-zero, something is still billing and the message says what.

To pause instead of destroy (keeps the disks at USD 47.60/month, kills the
compute charge):

```bash
aws ec2 stop-instances --region eu-central-1 --instance-ids \
  $(terraform output -json instance_ids | jq -r '.[]' | tr '\n' ' ')
```

Public addresses change on restart, so `kubeconfig.yaml` and the ssh targets
have to be refreshed after starting again. The cluster itself survives: every
node talks on its private address, which does not change.

---

## What to write down while it runs

The rows in `../PORTABILITY.md` section 3, plus the five differences this
directory already found before a single instance existed. Those five are worth
stating in the article as "found while preparing", because they are the
difference between a cloud that is portable and a cloud that says it is:

1. **The metadata service needs a token.** Hetzner answers a GET. AWS wants a
   PUT for a session token first, and the instances here are configured with
   `http_tokens = required` so the difference cannot be skipped.
2. **`providerID` carries the zone.** `hcloud://<id>` versus
   `aws:///<az>/<instance-id>`, because an instance id is only unique within a
   region.
3. **The firewall exists before the host does.** Hetzner's `install.sh` has to
   call the provider API to close the kubelet port after boot; on AWS the
   security group is attached at launch, so the window in GOTCHAS item 19 never
   opens.
4. **The cloud controller discovers nothing.** It authenticates as the instance
   (better: no token in a Secret) but has to be told its VPC, subnet, zone and
   cluster id in a config file, because on a self-managed cluster nothing
   supplies them. EKS supplies all four, which is the real content of the EKS
   management fee.
5. **The address itself is billable.** AWS charges USD 0.005/hour per public
   IPv4, about USD 18/month across five nodes. Hetzner includes it. There is no
   Hetzner line item to compare it to, which is the finding.

And one prediction to check rather than assume: `../PORTABILITY.md` guessed
that RWX storage would be the biggest cost difference. On AWS that guess is
**wrong**: EFS bills what you use with no minimum, so the 5 GiB event log is
about USD 1.80/month. Whether it holds for GCP Filestore, which does have a
minimum, is still open.
