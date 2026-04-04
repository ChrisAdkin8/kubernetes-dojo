# ─── Launch Template ──────────────────────────────────────────────────────────
# Enforces IMDSv2 (hop_limit=1 blocks pod metadata credential theft) and sets
# the root volume spec. Do NOT set ami_id or instance_type here — EKS manages
# the AMI for managed node groups and instance_type belongs on the node group.

resource "aws_launch_template" "node_group" {
  name_prefix = "${var.cluster_name}-${var.node_group_name}-"
  description = "Launch template for EKS managed node group: ${var.node_group_name}"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.disk_size_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.cluster_name}-${var.node_group_name}-node"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.tags, {
      Name = "${var.cluster_name}-${var.node_group_name}-volume"
    })
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

# ─── Managed Node Group ───────────────────────────────────────────────────────

resource "aws_eks_node_group" "this" {
  cluster_name    = var.cluster_name
  node_group_name = var.node_group_name
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = var.instance_types
  capacity_type   = var.capacity_type

  scaling_config {
    desired_size = var.desired_count
    min_size     = var.min_count
    max_size     = var.max_count
  }

  update_config {
    # Allow one node to be unavailable during rolling updates.
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.node_group.id
    version = aws_launch_template.node_group.latest_version
  }

  # Ignore desired_size so the cluster autoscaler can scale nodes freely
  # without Terraform reverting its changes on the next apply.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  tags = merge(var.tags, {
    "k8s.io/cluster-autoscaler/enabled"             = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  })

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ecr_read_only,
  ]
}
