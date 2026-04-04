# Exercise 07 — Cost and Efficiency

## Learning Objectives

By the end of this exercise you will be able to:

- Configure GPU time-slicing to increase pod density on a single GPU
- Explain when to use time-slicing vs MIG vs separate GPU nodes
- Use Spot GPU instances and understand interruption handling
- Apply ResourceQuota to cap GPU consumption per namespace

---

## Background

GPU instances are the most expensive compute in most ML platforms. Three techniques reduce cost:

### GPU time-slicing

Time-slicing configures the NVIDIA Device Plugin to advertise multiple virtual GPUs from a single physical GPU. Each virtual GPU gets a time slice of the physical GPU's compute, similar to CPU time-sharing.

```
Physical GPU (T4, 16 GB vRAM)
├── Virtual GPU 0  →  Pod A (gets 1/4 of compute time, full 16 GB vRAM visible)
├── Virtual GPU 1  →  Pod B (gets 1/4 of compute time, full 16 GB vRAM visible)
├── Virtual GPU 2  →  Pod C (gets 1/4 of compute time, full 16 GB vRAM visible)
└── Virtual GPU 3  →  Pod D (gets 1/4 of compute time, full 16 GB vRAM visible)
```

**Tradeoff:** vRAM is not partitioned — each pod can allocate up to 16 GB, so OOM can affect all pods. Best suited for inference workloads with low memory footprint and bursty compute patterns.

### MIG (Multi-Instance GPU)

MIG (available on A100 and H100) partitions the physical GPU at the hardware level into isolated instances, each with a guaranteed slice of compute, memory, and bandwidth. Unlike time-slicing, MIG instances cannot interfere with each other.

| GPU | MIG profiles available |
|---|---|
| A100 (40 GB) | 7× 1g.5gb, 4× 2g.10gb, 3× 3g.20gb, 1× 7g.40gb |
| H100 (80 GB) | 7× 1g.10gb, 4× 2g.20gb, 2× 4g.40gb, 1× 7g.80gb |

MIG is not available on T4 or A10G. Use time-slicing on those.

### Spot GPU instances

AWS Spot instances offer up to 70% discount over On-Demand but can be interrupted with 2 minutes' notice. Strategies to handle interruption:

- Checkpoint frequently (exercise 06) so training resumes after re-scheduling
- Use `spot_interruption_handler` (e.g. the AWS Node Termination Handler) to drain pods gracefully on interruption notice
- Set `completionMode: Indexed` on Jobs so only the interrupted worker pod is restarted, not all workers

### ResourceQuota

ResourceQuota caps the total `nvidia.com/gpu` requests in a namespace. This prevents any single team or workload from monopolising GPU capacity:

```yaml
hard:
  requests.nvidia.com/gpu: "4"
  limits.nvidia.com/gpu: "4"
```

---

## Prerequisites

```bash
export CLUSTER_NAME=my-eks-cluster

GPU_NODE=$(kubectl get nodes -l workload-type=gpu -o jsonpath='{.items[0].metadata.name}')
echo "GPU node: $GPU_NODE"
kubectl describe node "$GPU_NODE" | grep "nvidia.com/gpu"
```

---

## Step 1 — Configure GPU time-slicing

Time-slicing is configured via a ConfigMap that the NVIDIA Device Plugin reads:

```bash
kubectl apply -f manifests/time-slicing-configmap.yaml

# Patch the device plugin DaemonSet to reference the ConfigMap
kubectl patch daemonset nvidia-device-plugin-daemonset -n kube-system \
  --type=json \
  -p='[
    {"op": "add", "path": "/spec/template/spec/volumes/-",
     "value": {"name": "config", "configMap": {"name": "device-plugin-config"}}},
    {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-",
     "value": {"name": "config", "mountPath": "/etc/nvidia/config"}},
    {"op": "add", "path": "/spec/template/spec/containers/0/env/-",
     "value": {"name": "CONFIG_FILE", "value": "/etc/nvidia/config/config.yaml"}}
  ]'

# Restart the device plugin to apply the new config
kubectl rollout restart daemonset nvidia-device-plugin-daemonset -n kube-system
kubectl rollout status daemonset nvidia-device-plugin-daemonset -n kube-system
```

---

## Step 2 — Verify virtual GPU count

```bash
kubectl describe node "$GPU_NODE" | grep "nvidia.com/gpu"
```

Before time-slicing:

```
  nvidia.com/gpu:  1
```

After time-slicing with `replicas: 4`:

```
  nvidia.com/gpu:  4
```

The node now advertises 4 allocatable GPUs. Schedule 4 pods requesting `nvidia.com/gpu: 1` and confirm all schedule simultaneously:

```bash
kubectl apply -f manifests/time-sliced-pods.yaml
kubectl get pods -l exercise=time-slicing -o wide
```

All 4 pods should be `Running` on the same node.

---

## Step 3 — Inspect Spot GPU node configuration

```bash
# Check node capacity type
kubectl get nodes -l workload-type=gpu \
  -o custom-columns='NAME:.metadata.name,CAPACITY-TYPE:.metadata.labels.eks\.amazonaws\.com/capacityType'

# Describe the node group to see Spot configuration
aws eks describe-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name gpu \
  --query "nodegroup.{capacityType:capacityType,instanceTypes:instanceTypes,spotAllocationStrategy:spotAllocationStrategy}"
```

---

## Step 4 — Install the AWS Node Termination Handler

The Node Termination Handler watches for EC2 Spot interruption notices (IMDS metadata) and cordons + drains the node before the 2-minute window expires:

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-node-termination-handler eks/aws-node-termination-handler \
  --namespace kube-system \
  --set enableSpotInterruptionDraining=true \
  --set enableScheduledEventDraining=true

kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-node-termination-handler
```

---

## Step 5 — Apply a GPU ResourceQuota

Create a namespace quota that caps total GPU requests at 2:

```bash
kubectl create namespace ml-team-a --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f manifests/gpu-resource-quota.yaml

# Confirm the quota
kubectl describe quota gpu-quota -n ml-team-a
```

Try to exceed it:

```bash
# Schedule 3 GPU pods in the quota-limited namespace — the third should be rejected
for i in 1 2 3; do
  kubectl run gpu-test-$i -n ml-team-a \
    --image=nvidia/cuda:12.3.0-base-ubuntu22.04 \
    --restart=Never \
    --overrides='{"spec":{"tolerations":[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}],"nodeSelector":{"workload-type":"gpu"},"containers":[{"name":"gpu-test-'$i'","image":"nvidia/cuda:12.3.0-base-ubuntu22.04","command":["sleep","120"],"resources":{"requests":{"nvidia.com/gpu":"1"},"limits":{"nvidia.com/gpu":"1"}}}]}}'
done

kubectl get pods -n ml-team-a
kubectl describe quota gpu-quota -n ml-team-a | grep -A 10 "Resource"
```

---

## Step 6 — Clean up

```bash
kubectl delete pods -l exercise=time-slicing --ignore-not-found
kubectl delete pods -n ml-team-a --all --ignore-not-found
kubectl delete namespace ml-team-a --ignore-not-found
helm uninstall aws-node-termination-handler -n kube-system --ignore-not-found

# Revert device plugin to default (remove time-slicing config)
kubectl delete configmap device-plugin-config -n kube-system --ignore-not-found
kubectl rollout restart daemonset nvidia-device-plugin-daemonset -n kube-system
```

---

## Knowledge Check

1. With time-slicing configured to `replicas: 4`, how much vRAM does each virtual GPU pod have access to?
2. A time-sliced pod allocates 14 GB of vRAM. A second pod on the same GPU tries to allocate 4 GB. What happens?
3. What is the key advantage of MIG over time-slicing?
4. A Spot GPU node receives an interruption notice. How long does the Node Termination Handler have to drain it?
5. A namespace has `requests.nvidia.com/gpu: 2` quota. A team applies a Job with `parallelism: 4`, each pod requesting 1 GPU. What happens?
6. Your GPU node has 1 physical GPU time-sliced into 4. Three pods are running, each lightly using compute. A fourth pod starts a GPU-intensive task. What happens to the other three pods?

<details>
<summary>Answers</summary>

1. All 16 GB — vRAM is not partitioned by time-slicing. Each virtual GPU sees the full physical GPU memory, which is why time-slicing is risky: a single pod can OOM-kill the GPU process for all other pods sharing that physical GPU.
2. The second pod's CUDA allocation attempt fails with an out-of-memory error at runtime. The first pod holds 14 GB; only 2 GB remain. The Kubernetes scheduler does not know this — it sees 1 GPU available and schedules the pod. The OOM happens inside the container.
3. MIG provides hardware-enforced isolation: each MIG instance has a guaranteed slice of SM compute, memory bandwidth, and a fixed vRAM partition. A runaway process in one MIG instance cannot affect others. Time-slicing provides none of these guarantees — it is cooperative sharing with no memory isolation.
4. 2 minutes — that is the standard EC2 Spot interruption notice period. The Node Termination Handler must cordon the node and evict all pods within this window. For pods with `terminationGracePeriodSeconds` exceeding 2 minutes, the eviction may be forceful.
5. The first two pods schedule and claim the 2-GPU quota. The third and fourth pods are rejected by the API server with a quota exceeded error before they are even created. The Job will show 2 active pods and 2 pods that failed to be admitted.
6. The three lighter pods experience degraded performance — their time slices are compressed as the fourth pod demands more compute. Time-slicing does not enforce equal sharing; the scheduler on the GPU hardware allocates time based on demand. The light pods may stall or slow down depending on the GPU's scheduling policy.

</details>
