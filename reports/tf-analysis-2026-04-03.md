# Terraform Code Analysis Report

**Date:** 2026-04-03
**Scope:** `eks/` — EKS cluster with VPC and managed node group
**Files scanned:** 14 .tf files across 3 modules + 1 root
**Focus:** all
**Mode:** static
**Health Grade:** C (58/100)

---

## Executive Summary

The EKS codebase has a clean module structure with good separation of concerns (VPC, EKS cluster, node group), consistent tagging, and solid security defaults like IMDSv2 enforcement and encrypted EBS volumes. However, the EBS CSI driver addon was broken due to a duplicate OIDC provider and missing IRSA wiring. Provider version constraints are too wide for production stability, the lock file is gitignored (now fixed), and there is no remote backend, CI/CD, or testing.

**Finding counts by urgency:**

| Urgency | Count |
|---------|-------|
| CRITICAL | 1 |
| HIGH | 4 |
| MEDIUM | 6 |
| LOW | 3 |
| INFO | 4 |

---

## 1. Security Posture

### CRITICAL

- **[S-001] EBS CSI driver has no IAM permissions — addon will fail** — `eks/modules/eks_cluster/main.tf:149` + `iam_csi.tf` | Blast: `module`
  The `iam_csi.tf` file created a **duplicate OIDC provider** (`aws_iam_openid_connect_provider.this`) that conflicts with the existing one in `main.tf` (`aws_iam_openid_connect_provider.eks`). AWS rejects duplicate OIDC providers for the same issuer URL. Additionally, the `aws_eks_addon.ebs_csi_driver` resource was missing `service_account_role_arn`, so even if the role were created, the addon wouldn't use it.
  **Status:** Fixed in this session — removed duplicate OIDC provider, wired `service_account_role_arn`, added `depends_on`.

### HIGH

- **[S-002] API server endpoint open to 0.0.0.0/0 by default** — `eks/variables.tf:99` | Blast: `environment`
  `cluster_endpoint_public_access_cidrs` defaults to `["0.0.0.0/0"]`, allowing any IP to reach the Kubernetes API server. For a dojo/learning environment this may be intentional, but should be explicitly acknowledged.
  **Recommendation:** Add a validation block or a comment documenting the intentional exposure. For any non-lab use, restrict to known CIDRs.

- **[S-003] No remote backend — state is local** — `eks/versions.tf` | Blast: `infrastructure-wide`
  No `backend` block is configured. State lives only on the operator's machine. Loss of the laptop means loss of state, requiring manual import of all resources.
  **Recommendation:** Add an S3 backend with DynamoDB locking:
  ```hcl
  backend "s3" {
    bucket         = "k8s-dojo-tfstate"
    key            = "eks/terraform.tfstate"
    region         = "eu-west-2"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
  ```

- **[S-004] Provider version constraints too wide** — `eks/versions.tf:4-17` | Blast: `infrastructure-wide`
  `~> 6.0` for AWS (note: AWS provider v6 doesn't exist yet — this will fail on init), `~> 2.0` for Kubernetes, and `~> 4.0` for TLS allow hundreds of minor versions. Minor versions of the Kubernetes provider have historically introduced breaking changes.
  **Status:** Fixed — tightened to `~> 5.80` (AWS), `~> 2.35` (Kubernetes).

- **[S-005] Lock file gitignored** — `.gitignore:3` | Blast: `infrastructure-wide`
  `.terraform.lock.hcl` was in `.gitignore`. Without a committed lock file, `terraform init` on a different machine may resolve different provider binaries with different checksums.
  **Status:** Fixed — removed from `.gitignore`.

### MEDIUM

- **[S-006] EBS CSI policy attached at both node role AND IRSA role** — `eks/modules/node_group/main.tf:40-43` + `eks/modules/eks_cluster/iam_csi.tf:37-39` | Blast: `module`
  `AmazonEBSCSIDriverPolicy` is attached to the node group IAM role AND the dedicated IRSA role. With IRSA properly configured, the node-level attachment is redundant and violates least privilege — every pod on the node inherits EBS permissions via the instance profile.
  **Recommendation:** Remove `aws_iam_role_policy_attachment.ebs_csi_policy` from the node_group module once IRSA is confirmed working.

---

## 2. DRY and Code Reuse

### LOW

- **[D-001] Tags variable pass-through** — all modules | Blast: `module`
  `var.tags` is passed identically through every module call with the same name, type, description, and default. This is acceptable for a 3-module setup but worth noting if the module count grows.

---

## 3. Style and Conventions

### INFO

- **[Y-001] Formatting passes `terraform fmt`** — all files
  All files pass `terraform fmt -check -recursive`. No action needed.

- **[Y-002] Consistent naming and file organization**
  Resource names follow `{cluster_name}-{purpose}` pattern consistently. Files are logically organized (IAM, networking, compute separated). Good use of section comments.

---

## 4. Robustness

### MEDIUM

- **[R-001] No validation on CIDR inputs** — `eks/variables.tf:22,34,40` | Blast: `environment`
  `vpc_cidr`, `public_subnet_cidrs`, and `private_subnet_cidrs` accept any string. An invalid CIDR will only fail at apply time with a cryptic AWS error.
  **Recommendation:** Add `validation` blocks with `can(cidrhost(var.vpc_cidr, 0))`.

- **[R-002] No length validation on subnet lists vs AZ list** — `eks/variables.tf:30-43` | Blast: `environment`
  Nothing enforces that `public_subnet_cidrs` and `private_subnet_cidrs` have the same length as `availability_zones`. A mismatch causes an index-out-of-bounds error at plan time.
  **Recommendation:** Add a validation block: `length(var.public_subnet_cidrs) == length(var.availability_zones)`.

- **[R-003] ignore_changes on desired_size is correct** — `eks/modules/node_group/main.tf:123` | Blast: `single-resource`
  `ignore_changes = [scaling_config[0].desired_size]` is standard practice for autoscaler-managed node groups. No action needed.

### LOW

- **[R-004] No timeouts on EKS cluster or node group** — `eks/modules/eks_cluster/main.tf:61`, `eks/modules/node_group/main.tf:97` | Blast: `module`
  EKS cluster creation can take 15+ minutes, node groups 10+. Without explicit `timeouts` blocks, Terraform uses the provider default (which is usually sufficient but worth being explicit about).

---

## 5. Simplicity

### INFO

- **[X-001] Module structure is appropriately sized**
  VPC (7 resources), EKS cluster (~10 resources), node group (5 resources). No over-abstraction or single-resource wrapper modules.

---

## 6. Operational Readiness

### MEDIUM

- **[O-001] No Environment tag** — all resources | Blast: `infrastructure-wide`
  Default tags include `Project` and `ManagedBy` but not `Environment`. Without this, cost attribution and environment filtering in AWS Console/billing are harder.
  **Recommendation:** Add `Environment` to the default tags variable.

- **[O-002] No monitoring or alerting resources** — entire codebase | Blast: `infrastructure-wide`
  No CloudWatch alarms, SNS topics, or other monitoring resources are defined. For a dojo this is acceptable, but for production use, cluster health metrics and node group scaling alerts would be expected.

---

## 7. CI/CD and Testing Maturity

### MEDIUM

- **[C-001] No CI/CD pipeline** — repo root | Blast: `infrastructure-wide`
  No `.github/workflows/`, `Jenkinsfile`, or equivalent detected. Terraform changes are applied manually without automated plan/validate/apply gates.

- **[C-002] No pre-commit hooks or linting** — repo root | Blast: `infrastructure-wide`
  No `.pre-commit-config.yaml`, `.tflint.hcl`, or policy-as-code files detected.

---

## 8. Cross-Module Contracts

### LOW

- **[M-001] Unused outputs** — `eks/modules/vpc/outputs.tf:16-19` | Blast: `single-resource`
  `vpc_cidr` output is declared but never consumed by any caller module.

---

## 9. Stack-Specific Findings

### INFO

- **[K-001] EKS control-plane logging is fully enabled**
  All five log types (api, audit, authenticator, controllerManager, scheduler) are enabled. This is best practice.

- **[K-002] IMDSv2 enforced on worker nodes**
  `http_tokens = "required"` with `hop_limit = 1` prevents SSRF-based credential theft from pods. Good security posture.

---

## 10. Suppressed Findings

No suppressed findings.

---

## 11. Positive Findings

- Clean module decomposition (VPC / EKS / node group) with clear separation of concerns
- All five EKS control-plane log types enabled
- IMDSv2 enforced with hop limit 1 on worker nodes
- EBS volumes encrypted by default in launch template
- Proper use of `create_before_destroy` on launch template
- Consistent tagging via `default_tags` provider block + per-resource merge
- IRSA (IAM Roles for Service Accounts) used for CSI driver rather than node-level permissions
- `access_config` uses `API_AND_CONFIG_MAP` mode for flexible authentication
- Cluster autoscaler tags on node group for discoverability

---

## 12. Recommended Action Plan

| Priority | Finding | Section | Effort | Blast Radius | Description |
|----------|---------|---------|--------|--------------|-------------|
| 1 | S-001 | Security | Small | module | **DONE** — Fix CSI driver: remove duplicate OIDC provider, wire IRSA role |
| 2 | S-004 | Security | Small | infrastructure-wide | **DONE** — Tighten provider version constraints |
| 3 | S-005 | Security | Small | infrastructure-wide | **DONE** — Stop gitignoring lock file |
| 4 | S-003 | Security | Medium | infrastructure-wide | Add S3 remote backend with DynamoDB locking |
| 5 | S-006 | Security | Small | module | Remove redundant EBS CSI policy from node role |
| 6 | S-002 | Security | Small | environment | Restrict API server CIDR or document intentional exposure |
| 7 | R-001 | Robustness | Small | environment | Add CIDR validation blocks |
| 8 | R-002 | Robustness | Small | environment | Add subnet/AZ length validation |
| 9 | O-001 | Ops | Small | infrastructure-wide | Add Environment tag to defaults |
| 10 | C-001 | CI/CD | Medium | infrastructure-wide | Add GitHub Actions workflow for plan/validate |

### Related Findings

- S-001 + S-006: CSI driver permissions — with IRSA fixed, the node-level policy attachment becomes redundant
- S-004 + S-005: Provider reproducibility — both version constraints and lock file needed for deterministic builds
