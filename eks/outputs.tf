output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks_cluster.cluster_name
}

output "cluster_endpoint" {
  description = "API server endpoint URL for the EKS cluster."
  value       = module.eks_cluster.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded CA certificate for the cluster."
  value       = module.eks_cluster.cluster_ca_certificate
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC identity provider — required when creating IRSA IAM roles."
  value       = module.eks_cluster.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "URL of the OIDC identity provider (without https://)."
  value       = module.eks_cluster.oidc_provider_url
}

output "vpc_id" {
  description = "ID of the VPC that contains the cluster."
  value       = module.vpc.vpc_id
}

output "kubeconfig_command" {
  description = "Run this command to update your local kubeconfig and connect kubectl to the cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks_cluster.cluster_name}"
}
