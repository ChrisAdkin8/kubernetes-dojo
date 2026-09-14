# ─── VPC ─────────────────────────────────────────────────────────────────────

module "vpc" {
  source = "./modules/vpc"

  cluster_name         = var.cluster_name
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  tags                 = var.tags
}

# ─── EKS Control Plane ───────────────────────────────────────────────────────

module "eks_cluster" {
  source = "./modules/eks_cluster"

  cluster_name                         = var.cluster_name
  kubernetes_version                   = var.kubernetes_version
  vpc_id                               = module.vpc.vpc_id
  private_subnet_ids                   = module.vpc.private_subnet_ids
  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  tags                                 = var.tags
}

# ─── Worker Nodes ────────────────────────────────────────────────────────────

module "node_group" {
  source = "./modules/node_group"

  cluster_name       = module.eks_cluster.cluster_name
  node_group_name    = "general"
  private_subnet_ids = module.vpc.private_subnet_ids
  instance_types     = var.node_instance_types
  desired_count      = var.node_desired_count
  min_count          = var.node_min_count
  max_count          = var.node_max_count
  disk_size_gb       = var.node_disk_size_gb
  capacity_type      = var.node_capacity_type
  tags               = var.tags
}

# ─── GPU Worker Nodes ────────────────────────────────────────────────────────
# One managed node group per entry in var.gpu_node_groups (none by default).
# Each group gets its own IAM role so it doesn't collide with the general one.

module "gpu_node_group" {
  source   = "./modules/node_group"
  for_each = var.gpu_node_groups

  cluster_name       = module.eks_cluster.cluster_name
  node_group_name    = each.key
  private_subnet_ids = module.vpc.private_subnet_ids
  instance_types     = each.value.instance_types
  desired_count      = each.value.desired_size
  min_count          = each.value.min_size
  max_count          = each.value.max_size
  disk_size_gb       = coalesce(each.value.disk_size_gb, var.node_disk_size_gb)
  capacity_type      = each.value.capacity_type
  ami_type           = "AL2023_x86_64_NVIDIA"
  iam_role_name      = "${var.cluster_name}-${each.key}-node-group-role"
  tags               = var.tags

  # The exercises select GPU nodes on workload-type=gpu. The NVIDIA device
  # plugin chart's default affinity needs nvidia.com/gpu.present=true, which
  # nothing else sets on this cluster (no Node Feature Discovery). Merging
  # keeps both even when a learner sets labels of their own.
  labels = merge({
    "workload-type"          = "gpu"
    "nvidia.com/gpu.present" = "true"
  }, each.value.labels)

  taints = each.value.taints
}
