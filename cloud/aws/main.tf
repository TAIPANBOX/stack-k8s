# The AWS counterpart of the Hetzner cluster this repo was proven on.
#
# The shape is deliberately the SAME, not the AWS-idiomatic one: five VMs in one
# location on one private network, public IPs on the nodes, no NAT gateway, no
# managed control plane. That is the only way the comparison in PORTABILITY.md
# means anything. Where AWS forces a difference, the difference is commented
# here rather than smoothed over, because those comments are the deliverable.
#
# Nothing in this file is created until `terraform apply`. `terraform plan` is
# free. See ../COSTS.md for what apply starts costing: about USD 2.13/hour.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

provider "aws" {
  region = var.region

  # Every resource carries these, so the teardown sweep can find anything that
  # outlives the state file. An orphaned load balancer is the expensive kind.
  default_tags {
    tags = {
      Project   = "stack-k8s"
      Cluster   = var.cluster_name
      ManagedBy = "terraform"
      Ephemeral = "true"
    }
  }
}

# Canonical publishes the current AMI id as a public SSM parameter, so the
# region's image is resolved at apply time instead of pinned to something that
# goes stale. Verified 2026-07-25: Ubuntu 26.04 LTS ("Resolute Raccoon") exists
# in eu-central-1 as ami-0cd55f248a7e891a7, built 2026-07-22. That id is the
# fallback for var.ami_id if the parameter path ever moves.
data "aws_ssm_parameter" "ubuntu" {
  count = var.ami_id == "" ? 1 : 0
  name  = "/aws/service/canonical/ubuntu/server/${var.ubuntu_release}/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

locals {
  ami          = var.ami_id != "" ? var.ami_id : data.aws_ssm_parameter.ubuntu[0].value
  az           = "${var.region}${var.az_suffix}"
  cluster_tag  = "kubernetes.io/cluster/${var.cluster_name}"
  server_count = var.server_count
  agent_count  = var.agent_count
  node_count   = local.server_count + local.agent_count
  node_names   = [for i in range(local.node_count) : i < local.server_count ? "server-${i + 1}" : "agent-${i - local.server_count + 1}"]
}

# ---------------------------------------------------------------------------
# Network. 10.10.0.0/16 on purpose: the same CIDR the Hetzner private network
# used, so anything that hardcoded an address range behaves identically.
#
# ONE availability zone, also on purpose. AWS bills traffic between AZs at USD
# 0.01/GB in each direction, and a five-node etcd + Longhorn cluster is chatty.
# Hetzner's private network was free and had no such concept, so spreading
# across AZs here would add a cost line that has no counterpart in the baseline
# and would make the comparison dishonest. The trade is stated plainly: this
# cluster is not AZ-resilient, and neither was the Hetzner one.
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.cluster_name }
}

resource "aws_subnet" "nodes" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.10.0.0/24"
  availability_zone       = local.az
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.cluster_name}-nodes"
    # Both tags are load-bearing for the cloud controller, and neither is
    # obvious: without kubernetes.io/role/elb the service controller cannot
    # decide where to put a load balancer, and without the cluster tag it does
    # not consider the subnet to belong to this cluster at all. On EKS the
    # managed control plane applies these for you, which is exactly why they
    # are easy to miss on a self-managed cluster.
    "kubernetes.io/role/elb" = "1"
    (local.cluster_tag)      = "owned"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.cluster_name }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.cluster_name}-public" }
}

resource "aws_route_table_association" "nodes" {
  subnet_id      = aws_subnet.nodes.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# The security group is this cluster's equivalent of the Hetzner cloud firewall
# that install.sh creates: enforced outside the host, so a compromised node
# cannot switch it off, and free. Same posture: ssh and the Kubernetes API from
# the operator's address only, everything else between nodes, nothing else in.
#
# GOTCHAS.md item 19 measured what the default looks like without this: the
# kubelet API on :10250 reachable from the whole internet on every node.
# ---------------------------------------------------------------------------
resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-nodes"
  description = "stack-k8s nodes: operator access in, cluster traffic between nodes"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name                = "${var.cluster_name}-nodes"
    (local.cluster_tag) = "owned"
  }

  lifecycle {
    # The cloud controller adds its own rules here when it creates a load
    # balancer. Terraform must not revert them on the next apply.
    ignore_changes = [ingress, egress]
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = var.operator_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "ssh, operator only"
}

resource "aws_vpc_security_group_ingress_rule" "kubeapi" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = var.operator_cidr
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
  description       = "kube api, operator only"
}

resource "aws_vpc_security_group_ingress_rule" "icmp" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = var.operator_cidr
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
  description       = "ping, operator only"
}

# Everything between nodes: etcd, the kubelet, Calico's VXLAN, Longhorn's iSCSI
# and its NFS export for the RWX volume. Referencing the group itself rather
# than the CIDR means a node that somehow loses the group also loses access.
resource "aws_vpc_security_group_ingress_rule" "cluster" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1"
  description                  = "all cluster traffic between nodes"
}

# GOTCHAS.md item 11, in its AWS form. On Hetzner the load balancer's health
# check arrived from the balancer's own private address and the default-deny
# NetworkPolicy dropped it. Here the check arrives from the NLB's elastic
# network interfaces, which live IN this subnet and get addresses from it, so
# the source to admit is the subnet CIDR, not a single address. The rule has to
# be re-derived per cloud, which is exactly what PORTABILITY.md predicted.
resource "aws_vpc_security_group_ingress_rule" "nodeports" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = aws_subnet.nodes.cidr_block
  from_port         = 30000
  to_port           = 32767
  ip_protocol       = "tcp"
  description       = "NodePort range, for the load balancer and its health checks"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "all outbound"
}

# ---------------------------------------------------------------------------
# The nodes' own IAM role. This is a piece with NO Hetzner counterpart: there,
# the cloud controller authenticates with a project token handed to it in a
# Secret. On AWS the controller reads credentials from the instance it runs on,
# so the permission to create a load balancer is a property of the machine.
#
# Worth noting for the write-up: this is strictly better (no long-lived token
# in a Secret) and strictly more work (a role, a policy and a profile before
# anything can be created).
# ---------------------------------------------------------------------------
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "node" {
  name = "${var.cluster_name}-ccm"
  role = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # What the service controller needs to turn a type=LoadBalancer Service
        # into an NLB and keep its targets current.
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeRegions",
          "ec2:DescribeRouteTables",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcs",
          "ec2:DescribeAvailabilityZones",
          "ec2:CreateSecurityGroup",
          "ec2:CreateTags",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DeleteSecurityGroup",
          "elasticloadbalancing:*",
        ]
        Resource = "*"
      },
      {
        # The EFS CSI driver, only used if enable_efs is on. Harmless when the
        # filesystem does not exist.
        Effect = "Allow"
        Action = [
          "elasticfilesystem:DescribeFileSystems",
          "elasticfilesystem:DescribeMountTargets",
          "elasticfilesystem:DescribeAccessPoints",
          "elasticfilesystem:CreateAccessPoint",
          "elasticfilesystem:DeleteAccessPoint",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.cluster_name}-node"
  role = aws_iam_role.node.name
}

# ---------------------------------------------------------------------------
# The key. Generated on the operator's machine, never by AWS, so the private
# half has never left it.
# ---------------------------------------------------------------------------
resource "aws_key_pair" "operator" {
  key_name   = "${var.cluster_name}-operator"
  public_key = file(var.ssh_public_key_path)
}

# ---------------------------------------------------------------------------
# The nodes. Three servers (etcd members) and two agents, matching the Hetzner
# cluster exactly.
# ---------------------------------------------------------------------------
resource "aws_instance" "node" {
  count = local.node_count

  ami                         = local.ami
  instance_type               = var.instance_type
  availability_zone           = local.az
  subnet_id                   = aws_subnet.nodes.id
  vpc_security_group_ids      = [aws_security_group.nodes.id]
  key_name                    = aws_key_pair.operator.key_name
  iam_instance_profile        = aws_iam_instance_profile.node.name
  associate_public_ip_address = true

  # The single most expensive line in this file to have discovered by running
  # it. EC2 drops any packet leaving an interface whose SOURCE address is not
  # that interface's own, which is a sensible anti-spoofing default and is
  # fatal to a pod network.
  #
  # It bites here specifically BECAUSE of the single-AZ decision above. Calico
  # is configured VXLANCrossSubnet, meaning it encapsulates only when nodes are
  # on different subnets. All five nodes are deliberately on ONE subnet to
  # avoid cross-AZ charges, so Calico correctly decides not to encapsulate, and
  # every cross-node pod packet leaves with a 10.42.x.x source that AWS then
  # discards. Hetzner's private network has no equivalent check, so the exact
  # same Calico configuration works there unchanged.
  #
  # Turning the check off here rather than switching Calico to unconditional
  # VXLAN is deliberate: it keeps the Kubernetes configuration byte-identical
  # across both clouds and confines the difference to the infrastructure layer,
  # which is where a cloud difference belongs. See GOTCHAS.md item 44.
  source_dest_check = false

  root_block_device {
    volume_type = "gp3"
    volume_size = var.disk_gb
    encrypted   = true
    tags        = { Name = "${var.cluster_name}-${local.node_names[count.index]}" }
  }

  # IMDSv2 REQUIRED, not optional. This is the AWS trap PORTABILITY.md named:
  # Hetzner's metadata service answers a plain GET, AWS wants a PUT for a token
  # first. Leaving IMDSv1 enabled would hide the difference and make the run
  # less useful, so the harder setting is the deliberate one. install-aws.sh
  # does the token dance; anything else reading metadata has to as well.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # 2, so a pod can reach it too if it must
  }

  tags = {
    Name                = "${var.cluster_name}-${local.node_names[count.index]}"
    Role                = count.index < local.server_count ? "server" : "agent"
    (local.cluster_tag) = "owned"
  }
}

# ---------------------------------------------------------------------------
# EFS, for the "does a cloud-native RWX class behave like Longhorn" half of the
# storage comparison. OFF by default because it is metered, though barely:
# EFS Standard is USD 0.36/GB-month with NO minimum capacity, so the 5 GiB
# event log is about USD 1.80/month. That already answers one open question in
# PORTABILITY.md section 3, and answers it against the guess: RWX is not where
# AWS is expensive.
#
# The Longhorn path works here unchanged and stays the primary. This is the
# second data point, not a replacement.
# ---------------------------------------------------------------------------
resource "aws_efs_file_system" "events" {
  count = var.enable_efs ? 1 : 0

  creation_token   = "${var.cluster_name}-events"
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"
  encrypted        = true
  tags             = { Name = "${var.cluster_name}-events" }
}

resource "aws_security_group" "efs" {
  count = var.enable_efs ? 1 : 0

  name        = "${var.cluster_name}-efs"
  description = "NFS from the cluster nodes only"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.cluster_name}-efs" }
}

resource "aws_vpc_security_group_ingress_rule" "efs_nfs" {
  count = var.enable_efs ? 1 : 0

  security_group_id            = aws_security_group.efs[0].id
  referenced_security_group_id = aws_security_group.nodes.id
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
  description                  = "NFS from cluster nodes"
}

resource "aws_efs_mount_target" "events" {
  count = var.enable_efs ? 1 : 0

  file_system_id  = aws_efs_file_system.events[0].id
  subnet_id       = aws_subnet.nodes.id
  security_groups = [aws_security_group.efs[0].id]
}
