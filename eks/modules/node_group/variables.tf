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
