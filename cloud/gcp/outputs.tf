output "servers" {
  description = "Public addresses of the etcd members."
  value       = slice(google_compute_instance.node[*].network_interface[0].access_config[0].nat_ip, 0, local.server_count)
}

output "agents" {
  description = "Public addresses of the workers."
  value       = slice(google_compute_instance.node[*].network_interface[0].access_config[0].nat_ip, local.server_count, local.node_count)
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

output "hourly_usd" {
  description = "What apply started spending, from Google's own published rates for this region."
  value = format("%.4f",
    local.node_count * lookup({
      "c3d-highcpu-8"  = 0.35382064 # 8 x 0.03488434 core + 16 x 0.00467162 RAM
      "c3-highcpu-8"   = 0.40144544 # 8 x 0.040887   core + 16 x 0.00464684 RAM
      "c3d-standard-8" = 0.42027392 # 8 x 0.03488434 core + 32 x 0.00467162 RAM
    }, var.machine_type, 0)
    + local.node_count * 0.005                    # external IPv4, in use
    + local.node_count * var.disk_gb * 0.12 / 730 # pd-balanced
    + (var.enable_filestore ? 1024 * 0.19 / 730 : 0)
  )
}

output "next" {
  description = "The commands that follow a successful apply."
  value = <<-EOT

    Platform is provisioned. About USD ${format("%.2f",
  local.node_count * lookup({
    "c3d-highcpu-8"  = 0.35382064
    "c3-highcpu-8"   = 0.40144544
    "c3d-standard-8" = 0.42027392
  }, var.machine_type, 0)
  + local.node_count * 0.005
  + local.node_count * var.disk_gb * 0.12 / 730
  + (var.enable_filestore ? 1024 * 0.19 / 730 : 0)
)}/hour is now being spent.

    1. Everything else, one command:

         ./deploy-gcp.sh \
           --servers ${join(",", slice(google_compute_instance.node[*].network_interface[0].access_config[0].nat_ip, 0, local.server_count))} \
           --agents ${join(",", slice(google_compute_instance.node[*].network_interface[0].access_config[0].nat_ip, local.server_count, local.node_count))}

       Add --console-token <github-token> for the Genaryx console.

    2. When finished, and this is the part that matters:

         ./teardown.sh

  EOT
}
