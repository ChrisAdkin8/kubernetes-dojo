# ─── Cluster Security Group ───────────────────────────────────────────────────
# Additional security group applied to the control plane. EKS also creates its
# own cluster security group automatically; this one is for extra rules.

resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "Additional security group for EKS control plane communication."
  vpc_id      = var.vpc_id

  # Allow all outbound so the control plane can reach AWS service endpoints.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic."
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-cluster-sg"
  })
}

# ─── EKS Cluster ──────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_public_access  = var.cluster_endpoint_public_access
    endpoint_private_access = true
    public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  }

  # API_AND_CONFIG_MAP supports both IAM access entries and the legacy
  # aws-auth ConfigMap, giving maximum compatibility during migrations.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Ship API server, audit, authenticator, controller-manager, and scheduler
  # logs to CloudWatch Logs for observability and compliance.
  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller,
  ]
}
