# EKS Cluster — Terraform

This directory contains a Terraform configuration that provisions a production-quality Amazon EKS cluster for use with the `kubernetes-dojo` exercises.

## Architecture

```
VPC (10.0.0.0/16)
├── Public subnets  (one per AZ) — NAT gateways, future load balancers
└── Private subnets (one per AZ) — EKS control plane ENIs, worker nodes

EKS Control Plane
├── Authentication mode: API_AND_CONFIG_MAP
├── OIDC provider (for IRSA)
└── CloudWatch logging: API, Audit, Authenticator, Controller, Scheduler

Managed Node Group "general"
├── IMDSv2 enforced (launch template)
├── Encrypted gp3 root volumes
└── IAM role with EKSWorkerNode + CNI + ECR + EBS CSI policies

Managed Add-ons
├── vpc-cni
├── coredns
├── kube-proxy
└── aws-ebs-csi-driver
```

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Terraform | >= 1.9.0 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | >= 2.0 | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| kubectl | >= 1.29 | https://kubernetes.io/docs/tasks/tools/ |

Configure your AWS credentials before running any Terraform commands:

```bash
aws configure
# or
export AWS_PROFILE=your-profile
```

Verify that your identity has the necessary IAM permissions (EKS full access, IAM role/policy creation, VPC creation, EC2 management).

## Deploying the Cluster

### 1. Create your tfvars file

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. At minimum, set `region`:

```hcl
region = "eu-west-2"
```

To restrict API access to your IP only (recommended):

```hcl
cluster_endpoint_public_access_cidrs = ["YOUR.IP.HERE/32"]
```

### 2. Initialise Terraform

```bash
terraform init
```

### 3. Review the plan

```bash
terraform plan
```

You should see approximately 35–40 resources to be created.

### 4. Apply

```bash
terraform apply
```

This takes approximately 15–20 minutes. The EKS control plane takes ~10 minutes on its own.

### 5. Configure kubectl

After apply completes, run the output command:

```bash
$(terraform output -raw kubeconfig_command)
# expands to: aws eks update-kubeconfig --region eu-west-2 --name k8s-dojo
```

Verify connectivity:

```bash
kubectl get nodes
kubectl get pods -n kube-system
```

## Module Structure

```
eks/
├── versions.tf          — provider version constraints
├── main.tf              — module wiring
├── variables.tf         — all input variables with descriptions
├── outputs.tf           — cluster endpoint, OIDC ARN, kubeconfig command
├── terraform.tfvars.example
└── modules/
    ├── vpc/             — VPC, subnets, IGW, NAT GW, route tables
    ├── eks_cluster/     — IAM role, security group, EKS cluster, OIDC, add-ons
    └── node_group/      — IAM role, launch template, managed node group
```

## Variables

| Name | Default | Description |
|---|---|---|
| `region` | `eu-west-2` | AWS region |
| `cluster_name` | `k8s-dojo` | Name applied to all resources |
| `kubernetes_version` | `1.31` | EKS Kubernetes version |
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR block |
| `availability_zones` | `[eu-west-2a, eu-west-2b]` | AZs for subnet placement |
| `node_instance_types` | `[t3.medium]` | EC2 instance types for nodes |
| `node_desired_count` | `2` | Desired node count |
| `node_min_count` | `1` | Minimum node count |
| `node_max_count` | `4` | Maximum node count |
| `node_disk_size_gb` | `50` | Root EBS volume size |
| `node_capacity_type` | `ON_DEMAND` | `ON_DEMAND` or `SPOT` |
| `cluster_endpoint_public_access` | `true` | Expose API server publicly |
| `cluster_endpoint_public_access_cidrs` | `[0.0.0.0/0]` | Allowed CIDRs for public access |

## AWS Best Practices Applied

- **IMDSv2 enforced** — launch template sets `http_tokens = required` and `hop_limit = 1`, preventing SSRF attacks from reaching instance metadata.
- **Private worker nodes** — nodes run in private subnets and egress via NAT gateway; no public IPs on nodes.
- **Encrypted EBS volumes** — launch template enables EBS encryption on root volumes.
- **IRSA enabled** — OIDC provider created so ServiceAccounts can assume IAM roles without static credentials.
- **CloudWatch control-plane logs** — all five log types enabled for auditability.
- **Managed add-ons** — VPC CNI, CoreDNS, kube-proxy, and EBS CSI driver are managed by AWS and auto-patched.
- **Access entries** — authentication mode set to `API_AND_CONFIG_MAP`; the cluster creator receives admin permissions automatically.
- **Node autoscaler tags** — node group tagged for the [Cluster Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler/cloudprovider/aws).

## Destroying the Cluster

```bash
terraform destroy
```

> **Warning:** This deletes the VPC, all subnets, the EKS cluster, and the EBS volumes for any PersistentVolumeClaims with `reclaimPolicy: Delete`. Delete all PVCs before destroying if you want to retain the data.
