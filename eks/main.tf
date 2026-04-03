provider "aws" {
  region = var.region

  default_tags {
    tags = var.tags
  }
}

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
