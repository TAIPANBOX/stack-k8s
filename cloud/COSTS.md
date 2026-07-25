# What the AWS and GCP runs cost, before anything is created

Read this before running anything in `cloud/`. Every price below was pulled
from **AWS's own published price list** (`pricing.us-east-1.amazonaws.com`,
price list published 2026-07-20), region `eu-central-1` (Frankfurt), Linux,
shared tenancy, on demand. Nothing here is an estimate from a blog post.

The GCP half of this table is deliberately empty. It gets filled the same way,
from Google's own Cloud Billing Catalog API, when the GCP run starts.

---

## 1. The short version

| | Hetzner (measured) | AWS (published rates) |
|---|---|---|
| 5 nodes, 8 vCPU / 16 GB each | EUR 137 / month | **USD 1,487 / month** |
| Load balancer | EUR 7.49 / month | USD 19.71 / month + LCU |
| Node disks | included | USD 47.60 / month (5 x 100 GB) |
| Public IPv4 | included | USD 18.25 / month |
| Private network | EUR 0 | USD 0 (VPC itself is free) |
| **Burn while running** | about EUR 0.20 / hour | **about USD 2.16 / hour** |

The whole point of the exercise is that second column, so it is not a problem
that it is large. It is the finding.

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
| Any GCP resource | to be priced | **nothing prepared yet** |

---

## 7. GCP, when we get to it

To be filled from Google's own Cloud Billing Catalog API the same way, so the
three columns are comparable rather than impressionistic:

| Item | Rate | Monthly |
|---|---|---|
| 5 x `n2-standard-8` or `c3-standard-8` (8 vCPU / 32 GB) | | |
| Balanced persistent disk, 5 x 100 GB | | |
| External IP addresses | | |
| Network load balancer forwarding rules | | |
| Filestore for RWX, **at its minimum billable capacity** | | |
| GKE cluster management fee | | |
| Egress | | |

The one to watch: Filestore Basic HDD starts at 1 TiB minimum. If that holds,
the 5 GiB event log costs the same as 1 TiB, and GCP's RWX line will dwarf
AWS's USD 1.80. That is the single number most likely to decide the storage
section of the article, so it gets checked first.
