variable "project_id" {
  description = <<-EOT
    The GCP project everything is created in. A DEDICATED project, not a shared
    one: on GCP the project is the blast radius and the teardown boundary, so a
    project holding only this cluster can be deleted whole if the sweep ever
    misses something.
  EOT
  type        = string
}

variable "region" {
  description = "europe-west3 (Frankfurt) is about 250 km from Hetzner fsn1 and is the same city as the AWS run's eu-central-1, which is what makes the three columns comparable."
  type        = string
  default     = "europe-west3"
}

variable "zone_suffix" {
  description = "Single zone on purpose, exactly as the AWS run used a single AZ: GCP bills traffic between zones in the same region at USD 0.01/GB, and the Hetzner baseline had no such cost."
  type        = string
  default     = "-a"
}

variable "cluster_name" {
  description = "Names every resource and is the prefix the teardown sweep looks for. GCP resource names are RFC1035: lowercase letters, digits and hyphens."
  type        = string
  default     = "stack-k8s"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,50}[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name must be lowercase RFC1035: start with a letter, then letters, digits or hyphens."
  }
}

variable "machine_type" {
  description = <<-EOT
    c3d-highcpu-8 is 8 vCPU / 16 GiB on AMD EPYC Genoa: the same spec AND the
    same silicon family as Hetzner CPX42, at USD 0.353821/hour in Frankfurt
    (8 x 0.03488434 core + 16 x 0.00467162 RAM, Cloud Billing Catalog API,
    read 2026-07-26).

    c3-highcpu-8 is the Intel equivalent at USD 0.401445/hour, and it is NOT the
    default for two measured reasons. It is dearer, which on AWS was the other
    way round (c7a AMD cost MORE than c7i Intel there). And it has its own quota:
    C3_CPUS was 24 on this project against the 40 the cluster needs, while C3D
    draws on the general CPUS quota, which was 200. Choosing Intel here means
    filing a quota request first.
  EOT
  type        = string
  default     = "c3d-highcpu-8"
}

variable "disk_gb" {
  description = <<-EOT
    Matches the AWS run's 100 GB rather than CPX42's included 240 GB, for the
    same reason: the live Hetzner cluster claimed 14 GB of the 1200 it had.

    Watch the quota, which is tighter here than on AWS: pd-balanced counts
    against SSD_TOTAL_GB, and this project's limit in europe-west3 is 500 GB.
    Five 100 GB disks is exactly 500. It fits, with no headroom at all: a sixth
    node, or 120 GB disks, needs a quota increase first.

    Balanced PD is USD 0.12/GiB-month in Frankfurt, so 500 GB is USD 60/month
    against USD 47.60 for the same 500 GB of gp3 on AWS.
  EOT
  type        = number
  default     = 100
}

variable "operator_cidr" {
  description = <<-EOT
    Your public address, as a /32. ssh, the Kubernetes API and icmp are open to
    this and to nothing else. Get it with:

      curl -s https://checkip.amazonaws.com

    If your address changes mid-run you lock yourself out: re-apply with the new
    value, which is a 5 second change and not a rebuild.
  EOT
  type        = string

  validation {
    condition     = can(cidrnetmask(var.operator_cidr))
    error_message = "operator_cidr must be a CIDR block, for example 203.0.113.7/32."
  }

  validation {
    condition     = var.operator_cidr != "0.0.0.0/0"
    error_message = "0.0.0.0/0 puts the Kubernetes API on the public internet. That is GOTCHAS.md item 19, and it is the thing this cluster is supposed to prove it does not do."
  }
}

variable "ssh_public_key_path" {
  description = "The public half of the key generated for this run by preflight.sh. The private half never leaves the operator's machine and is never uploaded."
  type        = string
  default     = "~/.ssh/stack-k8s-gcp.pub"
}

variable "ssh_user" {
  description = "The login the key is bound to. On GCE the username is part of the ssh-keys metadata value, so it is a deliberate choice rather than an image default. ubuntu, to match the AWS run."
  type        = string
  default     = "ubuntu"
}

variable "image" {
  description = <<-EOT
    Canonical's own published family, resolved at apply time so the region's
    current build is used instead of a pin that goes stale. Verified 2026-07-26:
    ubuntu-2604-lts-amd64 resolves to ubuntu-2604-resolute-amd64-v20260723,
    which is the same release the Hetzner and AWS runs used.

    Pin by replacing the family with a full image name if a run has to be
    repeated byte for byte.
  EOT
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2604-lts-amd64"
}

variable "server_count" {
  description = <<-EOT
    etcd members. Three matches the Hetzner and AWS runs. etcd needs an ODD
    number or it cannot hold quorum, so 1, 3 or 5 and nothing else.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = contains([1, 3, 5], var.server_count)
    error_message = "etcd wants an odd number of members: 1, 3 or 5."
  }
}

variable "agent_count" {
  description = "Workers. Two matches the other two runs. Zero gives a 3-node cluster that still holds quorum and still satisfies Longhorn's 3 replicas, at 24 vCPU instead of 40."
  type        = number
  default     = 2
}

variable "can_ip_forward" {
  description = <<-EOT
    The GCP counterpart of the AWS instance flag that cost a day (GOTCHAS.md
    item 44). On EC2 the fix for a dropped pod network was source_dest_check =
    false; the GCE knob with the same shape is canIpForward.

    It is FALSE here on purpose, and that difference is a finding rather than an
    oversight. Turning it on is not enough on GCP: a GCE VPC has no layer 2 at
    all, so a packet addressed to 10.42.x.x is routed by the VPC, finds no route,
    and is dropped no matter what the sending instance is allowed to emit.
    Native pod routing would additionally need one VPC route per node, pointing
    at that node, for a CIDR block Calico's own IPAM allocates dynamically.

    So this deployment encapsulates instead: install-gcp.sh sets Calico to
    unconditional VXLAN rather than the VXLANCrossSubnet the other two clouds
    run. That is one word of Kubernetes configuration, and it is the ONLY
    Kubernetes-level difference across the three clouds. AWS let the difference
    stay in Terraform; GCP does not, and PORTABILITY.md should say so.

    Set true only if you are also creating the per-node routes by hand.
  EOT
  type        = bool
  default     = false
}

variable "enable_filestore" {
  description = <<-EOT
    Creates a Filestore instance for the second half of the RWX comparison.

    OFF by default and, unlike the AWS EFS counterpart, expensive: Filestore
    BASIC_HDD has a MINIMUM billable capacity of 1 TiB at USD 0.19/GiB-month in
    Frankfurt. The 5 GiB event log therefore costs USD 194.56/month here,
    against USD 1.80 on EFS, which bills what you use.

    That single number is the answer to the open question in PORTABILITY.md
    section 5, and it is answerable at a desk, which is why it is written down
    before anything is created. Longhorn is the primary RWX path on all three
    clouds and needs none of this.
  EOT
  type        = bool
  default     = false
}
