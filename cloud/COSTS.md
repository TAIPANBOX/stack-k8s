# What the AWS and GCP runs cost, before anything is created

Read this before running anything in `cloud/`. Every price below was pulled
from the provider's own published price list: **AWS**
(`pricing.us-east-1.amazonaws.com`, price list published 2026-07-20), region
`eu-central-1` (Frankfurt), Linux, shared tenancy, on demand; **GCP** (Cloud
Billing Catalog API, `cloudbilling.googleapis.com/v1/services/*/skus`, read
2026-07-26), region `europe-west3` (Frankfurt), on demand, USD. Nothing here is
an estimate from a blog post, and section 2 names the SKU behind every number.

---

## 1. The short version

| | Hetzner (measured) | AWS (published rates) | GCP (published rates) |
|---|---|---|---|
| 5 nodes, 8 vCPU / 16 GB each | EUR 137 / month | **USD 1,487 / month** | **USD 1,291 / month** |
| Load balancer | EUR 7.49 / month | USD 19.71 / month + LCU | USD 21.90 / month + USD 0.010/GiB |
| Node disks | included | USD 47.60 / month (5 x 100 GB) | USD 60.00 / month (5 x 100 GB) |
| Public IPv4 | included | USD 18.25 / month | USD 14.88 / month (first 744 IP-hours free) |
| Private network | EUR 0 | USD 0 (VPC itself is free) | USD 0 (VPC itself is free) |
| RWX, for a 5 GiB event log | EUR 0 (Longhorn) | USD 1.80 / month (EFS) | **USD 194.56 / month (Filestore)** |
| **Burn while running** | about EUR 0.20 / hour | **about USD 2.16 / hour** | **about USD 1.91 / hour** |

The whole point of the exercise is those second and third columns, so it is not
a problem that they are large. It is the finding.

Three things in that table are worth more than the totals:

- **GCP is the cheaper hyperscaler here, by about 13% on compute**, and the
  cheaper machine is the AMD one. On AWS the AMD part (`c7a`) cost MORE than the
  Intel part (`c7i`); on GCP `c3d` (AMD EPYC Genoa) is cheaper than `c3` (Intel
  Sapphire Rapids). The architecture-faithful choice is the cheap one on one
  cloud and the dear one on the other.
- **The public address costs the same rate on both**, to the cent: USD
  0.005/hour. GCP then gives away the first **744 IP-hours a month**, which is
  one address running for a full month, so a six hour five-node run pays nothing
  for its addresses while AWS bills from the first hour. Hetzner includes them
  outright. Three pricing philosophies for the same commodity, and only one of
  them shows up in a monthly-rate comparison.
- **RWX is where GCP is expensive and AWS is not.** That row answers the open
  question in `../PORTABILITY.md` section 5 and answers it both ways: the
  prediction was wrong on AWS and right on GCP, by a factor of 108.

**What matters operationally: the AWS cluster burns about USD 2.16 every hour
it exists.** A six hour working session is about USD 13. Forgetting it running
overnight is about USD 26. Forgetting it for a month is about USD 1,575.

---

## 2. Line by line, with the SKU each number came from

Region `eu-central-1`. All rates on demand, no commitment.

### Compute

| Instance | vCPU / RAM | USD / hour | 5 nodes, USD / month |
|---|---|---|---|
| `c7i.2xlarge` (Intel, **default here**) | 8 / 16 GiB | 0.4074 | 1,487.01 |
| `c7a.2xlarge` (AMD EPYC, closest to CPX42) | 8 / 16 GiB | 0.46852 | 1,710.10 |
| `m7i.2xlarge` (if 16 GB turns out tight) | 8 / 32 GiB | 0.4830 | 1,762.95 |

Hetzner CPX42 is AMD EPYC, so `c7a.2xlarge` is the architecture-faithful
comparison and `c7i.2xlarge` is the cheaper like-for-like on vCPU and RAM. The
default is `c7i`; switch with `-var instance_type=c7a.2xlarge` if the article
wants same-silicon rather than same-spec.

Monthly figures use 730 hours.

### Storage

| Item | Rate | Note |
|---|---|---|
| EBS `gp3` | USD 0.0952 / GB-month | 3,000 IOPS and 125 MB/s included |
| 5 x 100 GB (default here) | USD 47.60 / month | actual usage on Hetzner was 14 GB claimed |
| 5 x 240 GB (matching CPX42 exactly) | USD 114.24 / month | only if the article wants identical disks |
| EFS Standard | USD 0.36 / GB-month | for the RWX comparison, **no minimum size** |
| EFS One Zone | USD 0.192 / GB-month | single AZ, which is what this cluster is anyway |

The EFS number is worth flagging early because `PORTABILITY.md` guessed that
RWX storage would be the biggest cost difference. On AWS it is not: EFS bills
what you use, so the 5 GiB event log is about **USD 1.80 / month**. That guess
should be re-checked against GCP Filestore, which does have a large minimum.

### Network

| Item | Rate | Monthly |
|---|---|---|
| Public IPv4, in use | USD 0.005 / hour each | USD 3.65 each, **USD 18.25 for 5 nodes** |
| Network Load Balancer | USD 0.027 / hour | USD 19.71 + LCU |
| NLB capacity (LCU) | USD 0.006 / LCU-hour | demo traffic is well inside 1 LCU |
| VPC, subnets, internet gateway, security groups | USD 0 | |
| NAT gateway | **not used** | this design puts nodes in a public subnet, exactly as Hetzner did |
| Egress to internet | first 100 GB/month free, then about USD 0.09 / GB | Hetzner includes 20 TB per node |
| Cross-AZ traffic | USD 0.01 / GB each way | **avoided**: all 5 nodes in one AZ |

Two of these have no Hetzner counterpart at all and are worth writing up:
**AWS charges for the public IPv4 address itself**, which Hetzner includes in
the server price, and **AWS charges for traffic between availability zones**,
which is why this deployment deliberately stays in a single AZ.

### If we also test managed Kubernetes

| Item | Rate | Monthly |
|---|---|---|
| EKS control plane | USD 0.10 / hour per cluster | USD 73.00 |

This is on top of the nodes, not instead of them. It is a separate decision and
a separate approval, and the self-managed k3s run does not need it.

---

## 3. The hourly burn, which is the number that actually matters

The cluster as `cloud/aws/main.tf` builds it by default:

| Component | USD / hour |
|---|---|
| 5 x `c7i.2xlarge` | 2.0370 |
| 5 x public IPv4 | 0.0250 |
| 500 GB `gp3` | 0.0652 |
| **Base cluster** | **2.1272** |
| \+ NLB, while the load balancer test runs | 0.0270 |
| \+ EFS at 5 GiB, if we test EFS-backed RWX | 0.0025 |
| **Everything on** | **about 2.157** |

Round it to **USD 2.16 per hour with everything running**.

---

## 4. What is free, and stays free, until you say otherwise

Preparing the run costs nothing. Specifically, all of this is already done and
has spent no money:

- the SSH keypairs (`~/.ssh/stack-k8s-aws`, `~/.ssh/stack-k8s-gcp`)
- everything in `cloud/`: Terraform, the install script, the teardown script
- reading AWS's public price list, which needs no account at all

Money starts at exactly one command, and no earlier:

```bash
terraform apply
```

Nothing before it creates a billable resource. `terraform plan` is free and
shows the full list first.

---

## 5. Kill switches

Ordered by how fast they stop the meter.

1. **Everything, one command**, from `cloud/aws/`:

   ```bash
   ./teardown.sh
   ```

   This runs `terraform destroy` and then sweeps for the orphans Terraform does
   not know about, because the cloud controller creates the load balancer, not
   Terraform. An NLB that outlives its cluster keeps billing.

2. **Just the load balancer**, the only piece the CCM creates behind
   Terraform's back:

   ```bash
   kubectl -n agent-stack delete svc genaryx-console-lb
   ```

3. **Stop without destroying** (keeps the disks and the setup, kills about 95%
   of the burn). Stopped instances bill USD 0 for compute and release their
   public addresses, but the EBS volumes keep billing at USD 47.60 / month:

   ```bash
   aws ec2 stop-instances --region eu-central-1 --instance-ids \
     $(terraform output -json instance_ids | jq -r '.[]' | tr '\n' ' ')
   ```

   The nodes come back with different public addresses, so `kubeconfig.yaml`
   and the ssh targets need refreshing. The cluster itself is unaffected: every
   node talks on its private address, which survives a stop.

4. **A budget alarm**, so a forgotten cluster mails you instead of surprising
   you. `cloud/aws/README.md` step 6 sets one at USD 50 with an alert at 50%
   and 100%. AWS Budgets is free for the first two budgets.

---

## 6. What has to be approved before it can be spent

Nothing in this repo turns on a paid resource by itself. The decisions that
cost money, each one needing an explicit go:

| Decision | Cost | Default |
|---|---|---|
| Bring up the 5-node cluster | USD 2.13 / hour | **not created** |
| Attach a load balancer | \+ USD 0.027 / hour | **not created** (`50-loadbalancer.yaml` stays out of the kustomization) |
| Create the EFS filesystem for the RWX comparison | \+ USD 0.0025 / hour | **not created** (`enable_efs = false`) |
| Run an EKS cluster as well | \+ USD 0.10 / hour | **not planned** |
| Match Hetzner's 240 GB disks instead of 100 GB | \+ USD 0.09 / hour | **not set** (100 GB) |
| Any GCP resource | USD 1.88 / hour for the same shape | **not created**, and priced in section 7 |

---

## 7. GCP, line by line, with the SKU each number came from

Region `europe-west3` (Frankfurt), on demand, no commitment. Read from the Cloud
Billing Catalog API on 2026-07-26. Re-read any time with `./gcp/prices.sh`,
which needs no project and creates nothing.

### Compute

GCP prices a machine per CORE-hour plus per GiB-hour rather than per instance,
so each row below is a sum and a custom machine type is priceable by the same
formula. AWS quotes one number per instance type; neither is more honest, but
they are not directly comparable without doing this arithmetic.

| Machine | vCPU / RAM | USD / hour | 5 nodes, USD / month |
|---|---|---|---|
| `c3d-highcpu-8` (AMD EPYC Genoa, **default here**) | 8 / 16 GiB | 0.353821 | **1,291.44** |
| `c3-highcpu-8` (Intel Sapphire Rapids) | 8 / 16 GiB | 0.401445 | 1,465.28 |
| `c3d-standard-8` (if 16 GB turns out tight) | 8 / 32 GiB | 0.420274 | 1,533.99 |

SKUs: `C3D Instance Core running in Frankfurt` USD 0.03488434/hour and `C3D
Instance Ram running in Frankfurt` USD 0.00467162/GiB-hour; `C3 Instance Core`
USD 0.040887 and `C3 Instance Ram` USD 0.00464684.

`c3d-highcpu-8` is the like-for-like on BOTH spec and silicon: Hetzner CPX42 is
AMD EPYC and this is AMD EPYC, at 8 vCPU / 16 GiB exactly. On AWS those two
properties pulled in opposite directions and the default there had to choose
one. Here they agree, and the cheaper option is also the faithful one.

There is a second, non-price reason for the default, and it only shows up on a
real project: **quota is per machine family**. On the project this was written
against, `C3_CPUS` in `europe-west3` was 24 against the 40 this cluster needs,
while C3D has no family quota at all and draws on the general `CPUS` pool, which
was 200. The Intel option needs a quota request; the AMD one does not.

Monthly figures use 730 hours.

### Storage

| Item | Rate | Note |
|---|---|---|
| `pd-balanced` | USD 0.12 / GiB-month | SKU `Balanced PD Capacity in Frankfurt` |
| 5 x 100 GB (default here) | USD 60.00 / month | against USD 47.60 for the same 500 GB of AWS gp3 |
| 5 x 240 GB (matching CPX42 exactly) | USD 144.00 / month | only if the article wants identical disks |
| Filestore BASIC_HDD | USD 0.19 / GiB-month | **minimum 1 TiB**, so USD 194.56 / month whatever you ask for |
| Filestore ZONAL | USD 0.30 / GiB-month | minimum 1 TiB, USD 307.20 / month |
| Filestore REGIONAL | USD 0.54 / GiB-month | minimum 100 GiB with the small-instances feature, plus a USD 52.80 / month provisioning fee |
| Filestore BASIC_SSD | USD 0.36 / GiB-month | minimum 2.5 TiB, USD 921.60 / month |

Two things to carry into the write-up.

**pd-balanced counts against the SSD quota, not a disk quota.** `SSD_TOTAL_GB`
was 500 in this region, and five 100 GB disks is exactly 500: it fits with no
headroom at all. AWS had no equivalent ceiling in the way.

**The RWX prediction, settled.** `../PORTABILITY.md` guessed RWX storage would
be the biggest cost difference between clouds. On AWS that was wrong: EFS bills
what you use with no minimum, so the 5 GiB shared event log is USD 1.80/month.
On GCP it is right, and by a wide margin: the cheapest Filestore tier bills a
whole TiB, so the same 5 GiB is USD 194.56/month, **108 times the AWS line for
identical behaviour**. Longhorn is the primary RWX path on all three clouds and
needs none of this, which is exactly why it is the primary path.

### Network

| Item | Rate | Monthly |
|---|---|---|
| External IPv4 attached to a running VM | USD 0.005 / hour, **after 744 free IP-hours a month** | USD 14.88 for 5 nodes over a month, **USD 0 for a run under about 6 days** |
| Reserved address attached to NOTHING | USD 0.012 / hour after the first hour | USD 8.76, and it is 2.4x the rate of one doing work |
| Forwarding rule (regional passthrough NLB) | USD 0.030 / hour | USD 21.90 |
| Load balancer data processing | USD 0.010 / GiB | demo traffic is pennies |
| VPC, subnets, firewall rules, routes | USD 0 | |
| NAT gateway | **not used** | nodes are in a public subnet, exactly as the other two |
| Egress to internet, Frankfurt to western Europe | **USD 0.12 / GiB from the first GiB** | 0.11 above 1 TiB, 0.08 above 10 TiB |

The egress line is the one with no comfortable comparison: **AWS gives 100 GB a
month free and Hetzner includes 20 TB per node; GCP's allowance in this region
is none.** Distributing 1.5 GB of images from a laptop instead of over the
private network would cost about USD 0.18 here and nothing on AWS, which is why
`deploy-gcp.sh` builds on a node and ships over the private network.

The idle-address line is worth a sentence too: an address doing nothing costs
more than twice one carrying traffic. It is the cheapest thing on this page to
forget and the easiest to sweep, so `teardown.sh` looks for it explicitly.

### If we also test managed Kubernetes

| Item | Rate | Monthly |
|---|---|---|
| GKE cluster management fee (zonal, regional or Autopilot) | USD 0.10 / hour per cluster | USD 73.00 |
| GKE free tier credit | up to USD 74.40 / month per billing account | covers exactly one zonal or Autopilot cluster |

Identical to the EKS fee to the cent, with one difference that matters for a
demo: the free-tier credit means the FIRST zonal cluster's management fee is
effectively zero, while EKS charges from the first hour. The nodes are billed
either way, so this is a discount on the smaller half of the bill. Separate
decision, separate approval; the self-managed k3s run does not need it.

### The hourly burn, which is the number that actually matters

The cluster as `cloud/gcp/main.tf` builds it by default:

| Component | USD / hour |
|---|---|
| 5 x `c3d-highcpu-8` | 1.7691 |
| 5 x external IPv4 (0 while the 744 free IP-hours last) | 0.0250 |
| 500 GB `pd-balanced` | 0.0822 |
| **Base cluster** | **1.8763**, or 1.8513 for the first ~6 days |
| \+ forwarding rule, while the load balancer test runs | 0.0300 |
| \+ Filestore at its 1 TiB minimum, if we test it | 0.2665 |
| **Base plus load balancer** | **about 1.906** |

Round it to **USD 1.88 per hour for the cluster, USD 1.91 with the load
balancer**. Turning Filestore on adds more than the load balancer, the disks and
every public address combined, which is why it is off by default and why the
number is on this page rather than in a footnote.

A six hour working session is about USD 11.30. Forgetting it running overnight
is about USD 30. Forgetting it for a month is about USD 1,370.

### What has to be approved before it can be spent, GCP

| Decision | Cost | Default |
|---|---|---|
| Bring up the 5-node cluster | USD 1.88 / hour | **not created** |
| Attach a load balancer | \+ USD 0.030 / hour | **not created** (`loadbalancer-gcp.yaml` is applied by hand) |
| Create the Filestore instance for the RWX comparison | \+ USD 0.27 / hour | **not created** (`enable_filestore = false`) |
| Run a GKE cluster as well | \+ USD 0.10 / hour, first one credited | **not planned** |
| Match Hetzner's 240 GB disks instead of 100 GB | \+ USD 0.12 / hour | **not set** (100 GB, and 240 needs a quota increase) |
| Switch to the Intel `c3-highcpu-8` | \+ USD 0.24 / hour | **not set**, and it needs a quota increase first |
