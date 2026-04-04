# ─── Control Plane Assume-Role Policy ────────────────────────────────────────

data "aws_iam_policy_document" "eks_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

# ─── OIDC TLS Certificate ─────────────────────────────────────────────────────
# Required to register the cluster's OIDC issuer as an IAM identity provider.

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

# ─── EBS CSI Driver Trust Policy ─────────────────────────────────────────────
# Allows the ebs-csi-controller-sa service account to assume the CSI IAM role
# via IRSA (IAM Roles for Service Accounts). Scoped to the exact SA and audience
# to prevent privilege escalation from other service accounts.

data "aws_iam_policy_document" "ebs_csi_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
      type        = "Federated"
    }
  }
}
