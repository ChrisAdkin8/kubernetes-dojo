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
| kubectl | >= 1.29 | https://kubernetes.io/docs/tasks/tools/ |
| Helm | >= 3.14 | https://helm.sh/docs/intro/install/ |

Configure kubeconfig from the EKS cluster before starting any exercise:

```bash
export CLUSTER_NAME=my-eks-cluster
export AWS_REGION=eu-west-2
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
kubectl get nodes
```

---

## Provisioning GPU Nodes

GPU nodes are a separate managed node group added alongside the general node group in the EKS Terraform module. Add to `eks/terraform.tfvars`:

```hcl
gpu_node_groups = {
  gpu = {
    instance_types = ["g4dn.xlarge"]
    capacity_type  = "ON_DEMAND"
    min_size       = 0
    desired_size   = 1
    max_size       = 3
    labels = {
      "workload-type" = "gpu"
    }
    taints = [
      {
        key    = "nvidia.com/gpu"
        value  = "present"
        effect = "NO_SCHEDULE"
      }
    ]
  }
}
```

> **Warning:** GPU instances are expensive. Keep `desired_size = 0` when not running exercises and scale up only when needed:
> ```bash
> aws eks update-nodegroup-config \
>   --cluster-name "$CLUSTER_NAME" \
>   --nodegroup-name gpu \
>   --scaling-config desiredSize=1
> ```

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
3. The NVIDIA Device Plugin DaemonSet (`nvidia-device-plugin-daemonset`) — it discovers GPUs on each node and registers `nvidia.com/gpu` capacity with the kubelet.
4. `spec.parallelism` (pods running concurrently) and `spec.completions` set to the total work items, with `spec.completionMode: Indexed` so each pod receives a unique `JOB_COMPLETION_INDEX` to partition its share of the work.
5. `dcgm_gpu_utilization` (SM occupancy, %) vs `dcgm_fb_used` / `dcgm_fb_free` (framebuffer memory usage). High SM utilisation with modest memory usage = compute-bound. High memory usage with low SM = memory-bound or data-loading bottleneck.
6. A `tolerations` entry for the GPU node taint (`nvidia.com/gpu: NoSchedule`). Without it the scheduler will not place the pod on any tainted GPU node.
7. `ReadWriteMany` (RWX). EFS via the EFS CSI driver provides RWX; standard gp3 EBS does not.

</details>
