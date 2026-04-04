output "cluster_id" {
  description = "EKS cluster ID (same as name for EKS)."
  value       = aws_eks_cluster.this.id
}

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Endpoint URL of the EKS API server."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded CA certificate of the EKS cluster. Used to configure the Kubernetes provider."
  value       = aws_eks_cluster.this.certificate_authority[0].data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "ID of the additional cluster security group."
  value       = aws_security_group.cluster.id
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC identity provider. Used when creating IRSA IAM roles."
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "URL of the OIDC identity provider (without https://)."
  value       = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}

output "ebs_csi_role_arn" {
  description = "ARN of the IAM role used by the EBS CSI driver via IRSA."
  value       = aws_iam_role.ebs_csi.arn
}
