variable "region" {
  description = "eu-central-1 (Frankfurt) is about 250 km from Hetzner fsn1, which is what makes the latency numbers comparable."
  type        = string
  default     = "eu-central-1"
}

variable "az_suffix" {
  description = "Single AZ on purpose: AWS bills cross-AZ traffic at USD 0.01/GB each way, and the Hetzner baseline had no such cost."
  type        = string
  default     = "a"
}

variable "cluster_name" {
  description = "Names every resource and tags them for the cloud controller and the teardown sweep."
  type        = string
  default     = "stack-k8s"
}

variable "instance_type" {
  description = <<-EOT
    c7i.2xlarge is 8 vCPU / 16 GiB, matching Hetzner CPX42 on spec at USD
    0.4074/hour. c7a.2xlarge is the AMD EPYC equivalent, matching CPX42 on
    silicon at USD 0.46852/hour. Pick c7a if the article wants same-chip rather
    than same-spec.
  EOT
  type        = string
  default     = "c7i.2xlarge"
}

variable "disk_gb" {
  description = <<-EOT
    CPX42 includes 240 GB. On AWS the disk is billed separately at USD
    0.0952/GB-month, so 240 GB x 5 nodes is USD 114/month for space the live
    cluster never used (measured: 14 GB claimed of 1200 GB available). 100 GB
    leaves room for Longhorn's three replicas plus the images and costs USD
    47.60/month. Set 240 only if the write-up wants byte-identical disks.
  EOT
  type        = number
  default     = 100
}

variable "operator_cidr" {
  description = <<-EOT
    Your public address, as a /32. ssh, the Kubernetes API and ping are open to
    this and to nothing else. Get it with:

      curl -s https://checkip.amazonaws.com

    If your address changes mid-run you lock yourself out: re-apply with the
    new value, which is a 5 second change, not a rebuild.
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
  description = "The public half of the key generated for this run. The private half never leaves the operator's machine and is never uploaded."
  type        = string
  default     = "~/.ssh/stack-k8s-aws.pub"
}

variable "ubuntu_release" {
  description = "Matches the Hetzner run. Verified 2026-07-25: 26.04 LTS is published for eu-central-1."
  type        = string
  default     = "26.04"
}

variable "ami_id" {
  description = "Empty means resolve the current image from Canonical's public SSM parameter. Set it to pin, for example ami-0cd55f248a7e891a7 (Ubuntu 26.04 LTS, eu-central-1, built 2026-07-22)."
  type        = string
  default     = ""
}

variable "enable_efs" {
  description = <<-EOT
    Creates the EFS filesystem for the second half of the RWX comparison.
    Metered, but cheaply: USD 0.36/GB-month with no minimum capacity, so the
    5 GiB event log is about USD 1.80/month. Off by default because nothing in
    this repo turns on a paid resource without being asked.
  EOT
  type        = bool
  default     = false
}
