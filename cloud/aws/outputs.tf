output "servers" {
  description = "Public IPs of the three etcd members."
  value       = slice(aws_instance.node[*].public_ip, 0, local.server_count)
}

output "agents" {
  description = "Public IPs of the two workers."
  value       = slice(aws_instance.node[*].public_ip, local.server_count, local.node_count)
}

output "all_nodes" {
  description = "Every public IP, in install order. This is what build.sh wants."
  value       = aws_instance.node[*].public_ip
}

output "private_ips" {
  description = "The addresses every node actually talks on. Nothing cluster-internal crosses the public interface."
  value       = { for i, n in aws_instance.node : local.node_names[i] => n.private_ip }
}

output "instance_ids" {
  description = "Needed for the kubelet's provider-id, which install-aws.sh reads from the metadata service rather than from here."
  value       = { for i, n in aws_instance.node : local.node_names[i] => n.id }
}

output "efs_id" {
  description = "Empty unless enable_efs is on. Feeds the EFS CSI driver's storage class."
  value       = var.enable_efs ? aws_efs_file_system.events[0].id : ""
}

# The cloud controller cannot discover any of this on a self-managed cluster:
# on EKS it comes from the managed control plane's own configuration. Here it
# has to be written into a cloud config file, which install-aws.sh does using
# these values.
output "ccm_config" {
  description = "What the AWS cloud-controller-manager needs to be told."
  value = {
    vpc_id       = aws_vpc.this.id
    subnet_id    = aws_subnet.nodes.id
    zone         = local.az
    cluster_name = var.cluster_name
    sg_id        = aws_security_group.nodes.id
  }
}

output "next" {
  description = "The three commands that follow a successful apply."
  value = <<-EOT

    Platform is provisioned. About USD ${format("%.2f",
  local.node_count * lookup({ "c7i.2xlarge" = 0.4074, "c7a.2xlarge" = 0.46852, "m7i.2xlarge" = 0.4830 }, var.instance_type, 0)
  + local.node_count * 0.005
  + local.node_count * var.disk_gb * 0.0952 / 730
)}/hour is now being spent.

    1. Bring up the cluster:

         ./install-aws.sh \
           --servers ${join(",", slice(aws_instance.node[*].public_ip, 0, local.server_count))} \
           --agents ${join(",", slice(aws_instance.node[*].public_ip, local.server_count, local.node_count))} \
           --ssh-key ~/.ssh/stack-k8s-aws

    2. Build and distribute the images (unchanged from the Hetzner run, this
       part of the repo is not cloud-specific):

         cd ../.. && ./build.sh ${join(" ", [for ip in aws_instance.node[*].public_ip : "ubuntu@${ip}"])}

    3. Apply the workload:

         KUBECONFIG=cloud/aws/kubeconfig.yaml kubectl apply -k manifests/

    When finished, and this is the part that matters:

         ./teardown.sh

  EOT
}

# Rates in USD/hour for eu-central-1, Linux, shared tenancy, on demand, from
# AWS's own published price list (see ../COSTS.md section 2). AWS quotes one
# number per instance type, so unlike GCP no per-core arithmetic is needed.
#
# This output did not exist until 2026-09-01, and its absence was not neutral:
# the GCP side computes the figure from the counts actually being applied, while
# here the only number an operator ever saw was a sentence in preflight.sh and
# install-aws.sh asserting USD 2.13/hour. That figure is correct for the
# VARIABLE DEFAULTS, five nodes with 100 GB disks, and it does not follow the
# counts. Measured 2026-09-01 against the terraform.tfvars actually in this
# directory, three nodes with 60 GB disks: the real burn is 1.2607, and the
# scripts said 2.13. Nothing in the loop could notice, because no part of it
# computed anything; the sentence and the configuration simply drifted apart.
#
# The same shape had already been caught one directory over, where tfvars says
# three nodes, the scripts said 1.88, and terraform said 1.1258.
#
# The -1 default is copied from the GCP side deliberately, where it was earned:
# defaulting to 0 makes an unrecognised instance type print a confident figure
# that silently omits the largest line of the bill, and a cost output that is
# wrong in the cheap direction is worse than none, because it is believed.
locals {
  instance_rates = {
    "c7i.2xlarge" = 0.40740 # Intel Sapphire Rapids, 8 vCPU / 16 GiB, the default here
    "c7a.2xlarge" = 0.46852 # AMD EPYC, the silicon-faithful CPX42 comparison
    "m7i.2xlarge" = 0.48300 # 8 vCPU / 32 GiB, if 16 turns out tight
    "c7i.large"   = 0.10185 # 2 vCPU / 4 GiB, the smallest useful test node
  }
  instance_rate = lookup(local.instance_rates, var.instance_type, -1)
  hourly_total = (
    local.node_count * local.instance_rate
    + local.node_count * 0.005                      # public IPv4, billed in use
    + local.node_count * var.disk_gb * 0.0952 / 730 # gp3
    + (var.enable_efs ? 5 * 0.36 / 730 : 0)         # EFS Standard, billed on use, no minimum
  )
  hourly_text = local.instance_rate < 0 ? "UNKNOWN for ${var.instance_type}: add its rate to outputs.tf, or read ../COSTS.md section 2" : format("%.4f", local.hourly_total)
}

output "hourly_usd" {
  description = "What apply started spending, from AWS's own published rates for this region."
  value       = local.hourly_text
}
