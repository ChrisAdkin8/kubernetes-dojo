variable "cluster_name" {
  description = "Name of the EKS cluster that owns this node group."
  type        = string
}

variable "node_group_name" {
  description = "Name of the managed node group."
  type        = string
  default     = "general"
}

variable "private_subnet_ids" {
  description = "IDs of the private subnets in which nodes will be placed."
  type        = list(string)
}

variable "instance_types" {
  description = "EC2 instance types for the managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "desired_count" {
  description = "Desired number of nodes."
  type        = number
  default     = 2
}

variable "min_count" {
  description = "Minimum number of nodes."
  type        = number
  default     = 1
}

variable "max_count" {
  description = "Maximum number of nodes."
  type        = number
  default     = 4
}

variable "disk_size_gb" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 50
}

variable "capacity_type" {
  description = "ON_DEMAND or SPOT."
  type        = string
  default     = "ON_DEMAND"
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

variable "ami_type" {
  description = "EKS AMI type for the nodes (e.g. AL2023_x86_64_NVIDIA). Null lets EKS choose the default for the instance type."
  type        = string
  default     = null
}

variable "labels" {
  description = "Kubernetes labels applied to every node in the group."
  type        = map(string)
  default     = {}
}

variable "taints" {
  description = "Kubernetes taints applied to every node in the group. effect is NO_SCHEDULE, NO_EXECUTE or PREFER_NO_SCHEDULE."
  type = list(object({
    key    = string
    value  = optional(string)
    effect = string
  }))
  default = []
}

variable "iam_role_name" {
  description = "Name of the node IAM role. Null uses \"<cluster_name>-node-group-role\"."
  type        = string
  default     = null
}
