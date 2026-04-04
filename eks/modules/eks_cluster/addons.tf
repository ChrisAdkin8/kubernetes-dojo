# ─── EKS Managed Add-ons ──────────────────────────────────────────────────────
# Managed add-ons are patched and updated by AWS. OVERWRITE on update ensures
# Terraform changes take precedence over any in-cluster drift.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags

  # CoreDNS requires the VPC CNI to be ready before pods can schedule.
  depends_on = [aws_eks_addon.vpc_cni]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags

  # The IRSA role and its policy attachment must exist before the addon
  # attempts to start — otherwise the driver pod fails to authenticate.
  depends_on = [aws_iam_role_policy_attachment.ebs_csi]
}
