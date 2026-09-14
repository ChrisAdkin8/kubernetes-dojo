# GPU & ML Workloads on Kubernetes

This section covers running GPU-accelerated machine learning workloads on EKS. The exercises progress from bare GPU node provisioning through distributed training, model serving, monitoring, and cost optimisation.

## Architecture

```
EKS Cluster
├── GPU Node Group  (g4dn / g5 instances — private subnets)
│   ├── NVIDIA Device Plugin DaemonSet   — exposes nvidia.com/gpu resource to the scheduler
│   ├── DCGM Exporter DaemonSet          — GPU utilisation/memory/temperature metrics
│   └── Workload Pods                    — training Jobs, inference Deployments
│
├── System Node Group  (t3/t3a — general-purpose)
│   └── Monitoring stack  (Prometheus, Grafana)
│
└── Storage
    ├── EFS (ReadWriteMany)  — shared datasets, model checkpoints
    └── gp3 EBS             — node-local scratch, single-pod volumes
```

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Terraform | >= 1.9.0 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | >= 2.0 | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| kubectl | >= 1.35 | https://kubernetes.io/docs/tasks/tools/ |
| Helm | >= 3.14 | https://helm.sh/docs/intro/install/ |

Configure kubeconfig from the EKS cluster before starting any exercise:

```bash
export CLUSTER_NAME=$(terraform -chdir="$(git rev-parse --show-toplevel)/eks" output -raw cluster_name)
export AWS_REGION=eu-west-2
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
kubectl get nodes
```

---

## Provisioning GPU Nodes

GPU nodes are a separate managed node group added alongside the general node group by the EKS Terraform configuration (`gpu_node_groups` in `eks/variables.tf`). Each GPU group uses the AL2023 NVIDIA AMI, and gets the labels `workload-type=gpu` and `nvidia.com/gpu.present=true` and the taint `nvidia.com/gpu=present:NoSchedule` by default, which is what the exercises and the NVIDIA device plugin chart expect.

> **Warning:** If `eks/terraform.tfvars` already has a `gpu_node_groups` block copied from an earlier version of this README, the next `terraform apply` acts on it. Set its `desired_size` to 0 first, or the apply starts a GPU node (or fails, if your GPU quota is too low), and delete its `labels` unless you need extra ones.

Add to `eks/terraform.tfvars`, then run `terraform apply` in `eks/`:

```hcl
gpu_node_groups = {
  gpu = {
    instance_types = ["g4dn.xlarge"]
    # Optional, with their defaults:
    # capacity_type = "ON_DEMAND"
    # min_size      = 0
    # desired_size  = 0
    # max_size      = 2
  }
}
```

The group starts with no nodes. A g4dn.xlarge left running costs about $449/month in eu-west-2 ($0.615/hour), so scale up only for an exercise, and back to 0 when you finish.

### Check your GPU quota

EC2's "Running On-Demand G and VT instances" quota starts at 0 vCPUs on many accounts, and each g4dn.xlarge needs 4. Check yours before scaling up:

```bash
# The quota's code and the AWS default value
aws service-quotas list-aws-default-service-quotas --service-code ec2 --region "$AWS_REGION" \
  --query "Quotas[?QuotaName=='Running On-Demand G and VT instances'].[QuotaCode,Value]" --output text
QUOTA_CODE=$(aws service-quotas list-aws-default-service-quotas --service-code ec2 --region "$AWS_REGION" \
  --query "Quotas[?QuotaName=='Running On-Demand G and VT instances'].QuotaCode" --output text)

# Your account's applied value. If this fails with NoSuchResourceException,
# the default from the first command applies.
aws service-quotas get-service-quota --service-code ec2 --quota-code "$QUOTA_CODE" \
  --region "$AWS_REGION" --query Quota.Value
```

If the value is below 4 vCPUs per node you want to run (8 for exercise 03, which uses two nodes), request an increase in the Service Quotas console. AWS may take a while to grant it.

### Scaling the GPU group

Terraform ignores `desired_size` once the group exists, so scale it with the AWS CLI:

```bash
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name gpu \
  --scaling-config desiredSize=1

# When you're done:
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name gpu \
  --scaling-config desiredSize=0
```

The EKS NVIDIA AMI includes the NVIDIA driver but not the NVIDIA Kubernetes device plugin ([EKS accelerated AMIs](https://docs.aws.amazon.com/eks/latest/userguide/ml-eks-optimized-ami.html)), so a new GPU node doesn't advertise `nvidia.com/gpu` until you install the plugin in exercise 01.

### GPU instance families

| Family | GPU | vRAM | Use case |
|---|---|---|---|
| `g4dn` | NVIDIA T4 | 16 GB | Inference, small training runs |
| `g5` | NVIDIA A10G | 24 GB | Training, larger inference |
| `p3` | NVIDIA V100 | 16–32 GB | Distributed training |
| `p4d` | NVIDIA A100 | 40 GB × 8 | Large-scale distributed training |

---

## Exercise Structure

| # | Topic | Key concepts |
|---|---|---|
| 01 | GPU node setup | NVIDIA device plugin, `nvidia.com/gpu` resource, node taints, nvidia-smi |
| 02 | GPU scheduling | Resource requests = limits, tolerations, node selectors, GPU exclusivity |
| 03 | Distributed training | Indexed Jobs, PyTorch DDP, torchrun, RANK / WORLD_SIZE, worker coordination |
| 04 | Model serving | Resource limits, startup probes, GPU warmup, readiness, inference requests |
| 05 | GPU monitoring | DCGM Exporter, utilisation metrics, PromQL, alerting thresholds |
| 06 | Storage for ML | EFS RWX, shared dataset access, checkpoint patterns, NVMe scratch |
| 07 | Cost and efficiency | GPU time-slicing, MIG partitioning, Spot nodes, ResourceQuota |

---

## Knowledge Check

Answer without looking at the exercises or AWS console:

1. What Kubernetes resource name represents a GPU in a pod spec?
2. Why must GPU resource requests equal their limits?
3. What DaemonSet makes GPUs visible to the Kubernetes scheduler?
4. A training Job requires 4 GPUs but your nodes each have 1. What Job fields distribute work across 4 pods?
5. What metric from DCGM Exporter distinguishes a compute-bound GPU from a memory-bound one?
6. A pod requesting a GPU is stuck in `Pending`. The node has a free GPU. What is the most likely missing pod field?
7. What storage access mode is required for multiple training pods to read the same dataset simultaneously?

<details>
<summary>Answers</summary>

1. `nvidia.com/gpu` — set in both `resources.requests` and `resources.limits`.
2. GPU resources cannot be overcommitted. Kubernetes guarantees exclusive allocation per pod; partial or fractional GPU requests are not natively supported without time-slicing or MIG configured on the node.
3. The NVIDIA Device Plugin DaemonSet (`nvidia-device-plugin` when installed with Helm as in exercise 01; the chart names it after the release) — it discovers GPUs on each node and registers `nvidia.com/gpu` capacity with the kubelet.
4. `spec.parallelism` (pods running concurrently) and `spec.completions` set to the total work items, with `spec.completionMode: Indexed` so each pod receives a unique `JOB_COMPLETION_INDEX` to partition its share of the work.
5. Compare `DCGM_FI_DEV_GPU_UTIL` (percent of time a kernel was running) with `DCGM_FI_DEV_MEM_COPY_UTIL` (percent of time device memory was being read or written). High kernel activity with modest memory activity suggests compute-bound; high memory activity suggests memory-bandwidth-bound; both low during training suggests a data-loading bottleneck. `DCGM_FI_DEV_FB_USED` / `DCGM_FI_DEV_FB_FREE` show how much vRAM is in use, which is about capacity, not whether the GPU is memory-bound.
6. A `tolerations` entry for the GPU node taint (`nvidia.com/gpu: NoSchedule`). Without it the scheduler will not place the pod on any tainted GPU node.
7. `ReadWriteMany` (RWX). EFS via the EFS CSI driver provides RWX; standard gp3 EBS does not.

</details>
