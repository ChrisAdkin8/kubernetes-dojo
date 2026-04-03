variable "region" {
  description = "AWS region in which to deploy the EKS cluster."
  type        = string
  default     = "eu-west-2"
}

variable "cluster_name" {
  description = "Name applied to the EKS cluster and used as a prefix for all supporting resources."
  type        = string
  default     = "k8s-dojo"
}

variable "kubernetes_version" {
  description = "Kubernetes version to run on the control plane. Use a supported EKS version string (e.g. \"1.31\")."
  type        = string
  default     = "1.31"
}

# ─── Networking ──────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones to use. Must have at least two entries."
  type        = list(string)
  default     = ["eu-west-2a", "eu-west-2b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per availability zone)."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per availability zone). Worker nodes run here."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

# ─── Node Group ──────────────────────────────────────────────────────────────

variable "node_instance_types" {
  description = "EC2 instance types to use for the managed node group. The first entry is the primary type."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_count" {
  description = "Desired number of worker nodes."
  type        = number
  default     = 2
}

variable "node_min_count" {
  description = "Minimum number of worker nodes."
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum number of worker nodes."
  type        = number
  default     = 4
}

variable "node_disk_size_gb" {
  description = "Root EBS volume size (GiB) for each worker node."
  type        = number
  default     = 50
}

variable "node_capacity_type" {
  description = "Node capacity type: ON_DEMAND or SPOT."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

# ─── Cluster Access ──────────────────────────────────────────────────────────

variable "cluster_endpoint_public_access" {
  description = "Whether the EKS API server endpoint is reachable over the public internet."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs that are permitted to reach the public API endpoint. Default allows all."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ─── Tagging ─────────────────────────────────────────────────────────────────

variable "tags" {
  description = "Map of tags applied to all resources created by this configuration."
  type        = map(string)
  default = {
    Project   = "kubernetes-dojo"
    ManagedBy = "terraform"
  }
}
