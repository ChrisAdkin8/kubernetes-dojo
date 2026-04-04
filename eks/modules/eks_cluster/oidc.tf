# ─── OIDC Identity Provider ───────────────────────────────────────────────────
# Registers the cluster's OIDC issuer with IAM. Required for IRSA — pods can
# then exchange a Kubernetes service account token for short-lived AWS credentials
# without any long-lived secrets on the node.

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-oidc-provider"
  })
}
