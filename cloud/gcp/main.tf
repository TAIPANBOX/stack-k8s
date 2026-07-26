# The GCP counterpart of the Hetzner cluster this repo was proven on, and of
# cloud/aws/main.tf.
#
# The shape is deliberately the SAME as both, not the GCP-idiomatic one: five
# VMs in one zone on one private subnet, public addresses on the nodes, no NAT
# gateway, no managed control plane, no instance group and no autoscaler. That
# is the only way the comparison in ../PORTABILITY.md means anything. Where GCP
# forces a difference, the difference is commented here rather than smoothed
# over, because those comments are the deliverable.
#
# Nothing in this file is created until `terraform apply`. `terraform plan` is
# free. See ../COSTS.md for what apply starts costing: about USD 1.88/hour.

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.30"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = local.zone
}

locals {
  zone         = "${var.region}${var.zone_suffix}"
  node_tag     = "${var.cluster_name}-node"
  server_count = var.server_count
  agent_count  = var.agent_count
  node_count   = local.server_count + local.agent_count
  node_names   = [for i in range(local.node_count) : i < local.server_count ? "server-${i + 1}" : "agent-${i - local.server_count + 1}"]

  # Labels, on everything that can carry them. GCP labels are lowercase only,
  # and half the objects here cannot carry them at all: networks, subnetworks
  # and firewall rules have no labels, which is why teardown.sh sweeps by NAME
  # and by network rather than by label the way the AWS one sweeps by tag.
  labels = {
    project    = "stack-k8s"
    cluster    = var.cluster_name
    managed-by = "terraform"
    ephemeral  = "true"
  }

  # Google's own published health check probe ranges. Every load balancer health
  # check arrives from these two, and from nowhere else.
  # https://cloud.google.com/load-balancing/docs/health-check-concepts
  health_check_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
}

# ---------------------------------------------------------------------------
# Network. 10.10.0.0/24 inside a custom-mode VPC, the same range the Hetzner
# private network and the AWS VPC used, so anything that hardcoded an address
# range behaves identically on all three.
#
# auto_create_subnetworks = false on purpose. The default ("auto mode") creates
# a subnet in EVERY region, which is free but means the project quietly has
# addressing in places nobody chose. This VPC has exactly one subnet, in one
# region, and it is the one the nodes are in.
#
# ONE zone, also on purpose, and for the same reason the AWS run used one AZ:
# GCP bills traffic between zones of the same region, and a five-node etcd plus
# Longhorn cluster is chatty. The trade is stated plainly: this cluster is not
# zone-resilient, and neither were the other two.
# ---------------------------------------------------------------------------
resource "google_compute_network" "this" {
  name                    = var.cluster_name
  auto_create_subnetworks = false
  description             = "stack-k8s: one subnet, one zone, deliberately shaped like the Hetzner baseline"
}

resource "google_compute_subnetwork" "nodes" {
  name          = "${var.cluster_name}-nodes"
  ip_cidr_range = "10.10.0.0/24"
  region        = var.region
  network       = google_compute_network.this.id

  # Private Google Access, so a node with no public address could still reach
  # Google APIs. Free, and it costs nothing to have when the nodes do have
  # public addresses: it is the switch that would let a later run drop them.
  private_ip_google_access = true
}

# ---------------------------------------------------------------------------
# The firewall. This is the GCP form of the Hetzner cloud firewall install.sh
# creates and of the AWS security group: enforced outside the host, so a
# compromised node cannot switch it off, and free.
#
# GCP scopes rules by NETWORK TAG rather than by an object attached to the
# instance. That is the answer to GOTCHAS.md item 58 in its GCP form: a rule
# targeted at the tag applies to the nodes carrying it and to nothing else in
# the project, however many other machines the credential can see.
#
# GCP's implied rules are already deny-all inbound and allow-all outbound, so
# only the openings are written here.
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "operator" {
  name        = "${var.cluster_name}-operator"
  network     = google_compute_network.this.name
  description = "ssh, kube api and icmp, from the operator's address only"
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = [var.operator_cidr]
  target_tags   = [local.node_tag]

  allow {
    protocol = "tcp"
    ports    = ["22", "6443"]
  }
  allow {
    protocol = "icmp"
  }
}

# Everything between nodes: etcd, the kubelet, Calico's VXLAN, Longhorn's iSCSI
# and its NFS export for the RWX volume. Scoped by SOURCE TAG rather than by the
# subnet CIDR, which is the GCP equivalent of the AWS rule referencing its own
# security group: a machine that somehow loses the tag also loses access.
resource "google_compute_firewall" "internal" {
  name        = "${var.cluster_name}-internal"
  network     = google_compute_network.this.name
  description = "all cluster traffic between tagged nodes"
  direction   = "INGRESS"
  priority    = 1000

  source_tags = [local.node_tag]
  target_tags = [local.node_tag]

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

# GOTCHAS.md item 11, in its GCP form, and the third different answer to the
# same question. On Hetzner the load balancer's health check arrived from the
# balancer's own private address. On AWS it arrived from the NLB's network
# interfaces inside the subnet, so the rule had to admit the subnet CIDR. On GCP
# it arrives from two ranges Google publishes and that belong to no VPC at all,
# so the rule admits those two literal prefixes. Three clouds, three sources,
# one class of trap: the rule cannot be copied, it has to be re-derived.
#
# The whole NodePort range is opened rather than one port because
# externalTrafficPolicy: Local makes kube-proxy allocate a SEPARATE
# healthCheckNodePort, and its number is not known before the Service exists.
resource "google_compute_firewall" "health_checks" {
  name        = "${var.cluster_name}-health-checks"
  network     = google_compute_network.this.name
  description = "NodePort range, for load balancer health checks from Google's published probe ranges"
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = local.health_check_ranges
  target_tags   = [local.node_tag]

  allow {
    protocol = "tcp"
    ports    = ["30000-32767"]
  }
}

# ---------------------------------------------------------------------------
# The nodes' own identity. The GCP counterpart of the AWS instance profile, and
# the same finding applies: on Hetzner the cloud controller authenticates with a
# project token in a Secret, here it authenticates AS THE MACHINE, which is
# better because there is no long-lived token to leak, and more work because a
# service account and its bindings have to exist before any instance does.
#
# GCP adds one wrinkle AWS does not have: every project already ships a "default
# compute service account" that instances get automatically, and it holds the
# Editor role on the whole project. Using it would give every node in this
# cluster the ability to rewrite the project. This deployment creates its own
# and attaches it explicitly, which is the entire reason this block exists.
# ---------------------------------------------------------------------------
resource "google_service_account" "node" {
  account_id   = "${var.cluster_name}-node"
  display_name = "stack-k8s nodes: cloud controller, load balancers only"
}

# Load balancer objects: forwarding rules, target pools, health checks and the
# addresses they carry. Google maintains the list, so it does not go stale here.
resource "google_project_iam_member" "node_lb" {
  project = var.project_id
  role    = "roles/compute.loadBalancerAdmin"
  member  = "serviceAccount:${google_service_account.node.email}"
}

# What loadBalancerAdmin does NOT include, checked against the live role on
# 2026-07-26 rather than assumed: it can create the balancer but not the
# firewall rule that lets traffic reach it, and it cannot list zones. The
# in-tree GCE service controller does both. Rather than reach for
# roles/compute.securityAdmin, which also carries SSL certificates and security
# policies, this is exactly the missing set and nothing else.
resource "google_project_iam_custom_role" "node_extra" {
  role_id     = replace("${var.cluster_name}_ccm", "-", "_")
  title       = "stack-k8s cloud controller, firewall and lookups"
  description = "The permissions the GCE service controller needs that roles/compute.loadBalancerAdmin does not grant."
  permissions = [
    "compute.firewalls.create",
    "compute.firewalls.delete",
    "compute.firewalls.get",
    "compute.firewalls.list",
    "compute.firewalls.update",
    "compute.zones.get",
    "compute.zones.list",
    "compute.regions.get",
    "compute.regions.list",
    "compute.globalOperations.get",
  ]
}

resource "google_project_iam_member" "node_extra" {
  project = var.project_id
  role    = google_project_iam_custom_role.node_extra.id
  member  = "serviceAccount:${google_service_account.node.email}"
}

# ---------------------------------------------------------------------------
# The nodes. Three servers (etcd members) and two agents, matching both other
# clusters exactly.
# ---------------------------------------------------------------------------
resource "google_compute_instance" "node" {
  count = local.node_count

  name         = "${var.cluster_name}-${local.node_names[count.index]}"
  machine_type = var.machine_type
  zone         = local.zone
  tags         = [local.node_tag]
  labels       = merge(local.labels, { role = count.index < local.server_count ? "server" : "agent" })

  # See variables.tf: false, and the reason is the most interesting difference
  # this file records. The AWS run fixed a dropped pod network by turning the
  # equivalent check OFF; on GCP that would not be enough, because a GCE VPC
  # routes every packet and has no layer 2 to deliver a foreign destination on.
  # So the encapsulation moves into Calico instead, which is the one place the
  # three clouds' Kubernetes configuration is not identical.
  can_ip_forward = var.can_ip_forward

  boot_disk {
    initialize_params {
      image  = var.image
      size   = var.disk_gb
      type   = "pd-balanced"
      labels = local.labels
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.nodes.id

    # An ephemeral public address, PREMIUM tier. Standard tier is cheaper and
    # routes over the public internet rather than Google's backbone, which would
    # make the latency numbers incomparable with the other two runs.
    access_config {
      network_tier = "PREMIUM"
    }
  }

  metadata = {
    # On GCE the ssh username is part of the key metadata rather than a property
    # of the image, so it is chosen here.
    ssh-keys = "${var.ssh_user}:${trimspace(file(var.ssh_public_key_path))}"

    # OS Login OFF, explicitly. With it on, GCP ignores this key, derives the
    # username from the Google account instead, and every ssh line in this repo
    # and in the deploy scripts stops working with a permission error that names
    # neither OS Login nor the username. It is off by default today and Google
    # keeps moving toward on-by-default, so it is pinned rather than assumed.
    enable-oslogin = "FALSE"
  }

  service_account {
    email = google_service_account.node.email
    # cloud-platform, with the actual authority carried by the two role bindings
    # above. Scopes are the older, coarser layer of the same fence; narrowing
    # both means debugging which of the two denied a call.
    scopes = ["cloud-platform"]
  }

  # A machine_type change should not silently destroy and rebuild a running
  # cluster's node.
  allow_stopping_for_update = true

  lifecycle {
    ignore_changes = [
      # The kubelet and the cloud controller both label instances at runtime.
      metadata["created-by"],
    ]
  }
}

# ---------------------------------------------------------------------------
# Filestore, for the "does a cloud-native RWX class behave like Longhorn" half
# of the storage comparison. OFF by default, and here the default matters far
# more than it did on AWS.
#
# EFS has no minimum capacity, so the AWS answer to this question cost USD
# 1.80/month. Filestore BASIC_HDD starts at 1 TiB whatever you ask for, at USD
# 0.19/GiB-month in Frankfurt: USD 194.56/month for the same 5 GiB event log.
# That is 108 times the AWS line for identical behaviour, and it is the number
# PORTABILITY.md section 5 asked to have checked first.
#
# Longhorn is the primary RWX path on all three clouds and needs none of this.
# ---------------------------------------------------------------------------
resource "google_filestore_instance" "events" {
  count = var.enable_filestore ? 1 : 0

  name     = "${var.cluster_name}-events"
  location = local.zone
  tier     = "BASIC_HDD"
  labels   = local.labels

  file_shares {
    capacity_gb = 1024 # the minimum, not a choice
    name        = "events"
  }

  networks {
    network = google_compute_network.this.name
    modes   = ["MODE_IPV4"]
  }
}
