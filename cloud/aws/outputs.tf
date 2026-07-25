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
