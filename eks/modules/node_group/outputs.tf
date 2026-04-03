output "node_group_id" {
  description = "ID of the managed node group."
  value       = aws_eks_node_group.this.id
}

output "node_group_arn" {
  description = "ARN of the managed node group."
  value       = aws_eks_node_group.this.arn
}

output "node_role_arn" {
  description = "ARN of the IAM role attached to worker nodes."
  value       = aws_iam_role.node_group.arn
}

output "node_role_name" {
  description = "Name of the IAM role attached to worker nodes."
  value       = aws_iam_role.node_group.name
}
