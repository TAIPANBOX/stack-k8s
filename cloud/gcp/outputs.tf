# Every output below slices against the instances that ACTUALLY EXIST rather
# than against the counts that were asked for, and that is not defensive
# programming, it is a bug that cost a live cluster fifteen minutes.
#
# The first apply hit a quota ceiling and created three of five instances.
# Terraform evaluates outputs on every command, including the destroy that was
# needed to fix it, and `slice(list_of_3, 0, 5)` fails with "end index must not
# be greater than the length of the list". So the partial apply could not be
# torn down or reshaped until the outputs were repaired, with all three
# instances billing throughout. An output that only works when everything
# worked is an output that breaks exactly when it is needed.
locals {
  nat_ips  = google_compute_instance.node[*].network_interface[0].access_config[0].nat_ip
  n_actual = length(local.nat_ips)
  n_srv    = min(local.server_count, local.n_actual)
}

output "servers" {
  description = "Public addresses of the etcd members that exist."
  value       = slice(local.nat_ips, 0, local.n_srv)
}

output "agents" {
  description = "Public addresses of the workers that exist."
  value       = slice(local.nat_ips, local.n_srv, local.n_actual)
}

output "all_nodes" {
  description = "Every public address, in install order. This is what build.sh wants."
  value       = google_compute_instance.node[*].network_interface[0].access_config[0].nat_ip
}

output "private_ips" {
  description = "The addresses every node actually talks on. Nothing cluster-internal crosses the public interface."
  value       = { for i, n in google_compute_instance.node : local.node_names[i] => n.network_interface[0].network_ip }
}

output "instance_names" {
  description = "The kubelet's provider-id is gce://<project>/<zone>/<NAME>, so unlike AWS the name is the identifier, not an opaque id. install-gcp.sh reads it from the metadata service rather than from here."
  value       = google_compute_instance.node[*].name
}

output "filestore_ip" {
  description = "Empty unless enable_filestore is on. The address an NFS PersistentVolume would mount."
  value       = var.enable_filestore ? google_filestore_instance.events[0].networks[0].ip_addresses[0] : ""
}

# The cloud controller cannot discover any of this on a self-managed cluster:
# on GKE it comes from the managed control plane's own configuration. Here it
# has to be written into a gce.conf, which install-gcp.sh does using these
# values. Same finding as AWS, different four fields.
output "ccm_config" {
  description = "What the GCP cloud-controller-manager has to be told."
  value = {
    project_id      = var.project_id
    network_name    = google_compute_network.this.name
    subnetwork_name = google_compute_subnetwork.nodes.name
    node_tag        = local.node_tag
    local_zone      = local.zone
  }
}

# Rates in USD/hour for europe-west3, on demand, from the Cloud Billing Catalog
# API (see ../COSTS.md section 7 and ./prices.sh). GCP prices a machine per
# core-hour plus per GiB-hour, so each of these is that arithmetic done once.
#
# The -1 default is deliberate and was earned: the first version defaulted to 0,
# so choosing a machine type that was not in the table printed a confident
# "0.1072/hour" for a cluster about to burn 1.93. A cost output that silently
# omits the largest line is worse than no cost output, because it is believed.
locals {
  machine_rates = {
    "c3d-highcpu-8"  = 0.35382064 # 8 x 0.03488434 core + 16 x 0.00467162 RAM
    "c3d-standard-8" = 0.42027392 # 8 x 0.03488434      + 32 x 0.00467162
    "c3-highcpu-8"   = 0.40144544 # 8 x 0.040887        + 16 x 0.00464684
    "c3-standard-8"  = 0.47614688 # 8 x 0.040887        + 32 x 0.00464684
    "c2d-highcpu-8"  = 0.38630400 # 8 x 0.038088        + 16 x 0.0051
    "c2d-standard-8" = 0.46790400 # 8 x 0.038088        + 32 x 0.0051
    "n4-highcpu-8"   = 0.36126880 # 8 x 0.0368042       + 16 x 0.0041772
  }
  machine_rate = lookup(local.machine_rates, var.machine_type, -1)
  hourly_total = (
    local.node_count * local.machine_rate
    + local.node_count * 0.005                    # external IPv4, in use
    + local.node_count * var.disk_gb * 0.12 / 730 # pd-balanced
    + (var.enable_filestore ? 1024 * 0.19 / 730 : 0)
  )
  hourly_text = local.machine_rate < 0 ? "UNKNOWN for ${var.machine_type}: add its rate to outputs.tf, or price it with ./prices.sh" : format("%.4f", local.hourly_total)
}

output "hourly_usd" {
  description = "What apply started spending, from Google's own published rates for this region."
  value       = local.hourly_text
}

output "next" {
  description = "The commands that follow a successful apply."
  value       = <<-EOT

    Platform is provisioned. About USD ${local.hourly_text} per hour is now being spent.

    1. Everything else, one command:

         ./deploy-gcp.sh \
           --servers ${join(",", slice(local.nat_ips, 0, local.n_srv))} \
           --agents ${join(",", slice(local.nat_ips, local.n_srv, local.n_actual))}

       Add --console-token <github-token> for the Genaryx console, and
       --copilot-key-file <path> to point its copilot at a cloud model.

    2. When finished, and this is the part that matters:

         ./teardown.sh

  EOT
}
