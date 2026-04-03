variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS control plane."
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC in which the cluster resides."
  type        = string
}

variable "private_subnet_ids" {
  description = "IDs of the private subnets used for the EKS control plane ENIs."
  type        = list(string)
}

variable "cluster_endpoint_public_access" {
  description = "Whether the API server endpoint is reachable over the public internet."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs permitted to reach the public API endpoint."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
