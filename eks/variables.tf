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
  description = "Kubernetes version to run on the control plane (e.g. \"1.36\"). Use a version in EKS standard support: the cluster's upgrade policy is STANDARD, which cannot be set on a cluster that has already entered extended support."
  type        = string
  default     = "1.36"
}

# ─── Networking ──────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block (e.g. \"10.0.0.0/16\")."
  }
}

variable "availability_zones" {
  description = "List of availability zones to use. Must have at least two entries."
  type        = list(string)
  default     = ["eu-west-2a", "eu-west-2b"]

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least two availability zones are required for a highly available cluster."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets — one per availability zone."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]

  validation {
    condition     = alltrue([for c in var.public_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "All public_subnet_cidrs must be valid CIDR blocks."
  }

  validation {
    condition     = length(var.public_subnet_cidrs) == length(var.availability_zones)
    error_message = "public_subnet_cidrs must have exactly one entry per availability zone."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets — one per availability zone. Worker nodes run here."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]

  validation {
    condition     = alltrue([for c in var.private_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "All private_subnet_cidrs must be valid CIDR blocks."
  }

  validation {
    condition     = length(var.private_subnet_cidrs) == length(var.availability_zones)
    error_message = "private_subnet_cidrs must have exactly one entry per availability zone."
  }
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

# ─── GPU Node Groups ─────────────────────────────────────────────────────────

variable "gpu_node_groups" {
  description = <<-EOT
    GPU managed node groups, keyed by node group name. Each uses the AL2023
    NVIDIA AMI, and gets the labels workload-type=gpu and
    nvidia.com/gpu.present=true merged with any labels set here. desired_size
    defaults to 0, so no GPU node runs until you scale the group up. The GPU
    exercises expect a group named "gpu"; see gpu-ml/README.md.
  EOT
  type = map(object({
    instance_types = list(string)
    capacity_type  = optional(string, "ON_DEMAND")
    min_size       = optional(number, 0)
    desired_size   = optional(number, 0)
    max_size       = optional(number, 2)
    disk_size_gb   = optional(number)
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string
      })), [{
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    }])
  }))
  default = {}

  validation {
    condition     = alltrue([for g in values(var.gpu_node_groups) : contains(["ON_DEMAND", "SPOT"], g.capacity_type)])
    error_message = "gpu_node_groups capacity_type must be ON_DEMAND or SPOT."
  }

  validation {
    condition = alltrue(flatten([
      for g in values(var.gpu_node_groups) : [
        for t in g.taints : contains(["NO_SCHEDULE", "NO_EXECUTE", "PREFER_NO_SCHEDULE"], t.effect)
      ]
    ]))
    error_message = "gpu_node_groups taint effect must be NO_SCHEDULE, NO_EXECUTE or PREFER_NO_SCHEDULE."
  }
}

# ─── Cluster Access ──────────────────────────────────────────────────────────

variable "cluster_endpoint_public_access" {
  description = "Whether the EKS API server endpoint is reachable over the public internet."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = <<-EOT
    CIDRs permitted to reach the public EKS API endpoint.
    Defaults to 0.0.0.0/0 for convenience in a learning environment.
    For production, restrict to known egress CIDRs (e.g. your VPN or office IP range).
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for c in var.cluster_endpoint_public_access_cidrs : can(cidrhost(c, 0))])
    error_message = "All cluster_endpoint_public_access_cidrs must be valid CIDR blocks."
  }
}

# ─── Tagging ─────────────────────────────────────────────────────────────────

variable "tags" {
  description = "Map of tags applied to all resources created by this configuration."
  type        = map(string)
  default = {
    Project     = "kubernetes-dojo"
    ManagedBy   = "terraform"
    Environment = "lab"
  }
}
