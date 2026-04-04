# Exercise 01 — GPU Node Setup

## Learning Objectives

By the end of this exercise you will be able to:

- Identify GPU nodes in a cluster and inspect their allocatable resources
- Explain the role of the NVIDIA Device Plugin DaemonSet
- Verify that the `nvidia.com/gpu` resource is visible to the Kubernetes scheduler
- Run `nvidia-smi` inside a pod to confirm the GPU is accessible at runtime

---

## Background

Kubernetes has no built-in awareness of GPUs. The NVIDIA Device Plugin is a DaemonSet that runs on every GPU node, talks to the node's NVIDIA driver, and advertises `nvidia.com/gpu` as an extended resource to the kubelet. Without it, GPU nodes appear as ordinary CPU nodes and the scheduler cannot place GPU-requesting pods on them.

### GPU node lifecycle

| Stage | What happens |
|---|---|
| Node joins cluster | kubelet starts; no GPU capacity visible yet |
| Device plugin starts | Plugin discovers GPUs via NVML, registers capacity with kubelet |
| Scheduler sees capacity | `nvidia.com/gpu: N` appears in `kubectl describe node` |
| Pod scheduled | GPU is allocated exclusively to that pod; others cannot use it |
| Pod exits | GPU is released back to allocatable capacity |

### GPU node taints

GPU nodes are tainted by convention so that general-purpose pods do not consume GPU capacity accidentally:

```
nvidia.com/gpu=present:NoSchedule
```

Any pod that wants to run on a GPU node must include a matching `toleration`. This is the most common reason GPU pods get stuck in `Pending`.

---

## Prerequisites

```bash
export CLUSTER_NAME=my-eks-cluster
export AWS_REGION=eu-west-2

# Confirm kubeconfig is pointed at the right cluster
kubectl config current-context

# Confirm at least one GPU node is ready
kubectl get nodes -l workload-type=gpu
```

---

## Step 1 — List GPU nodes

```bash
# List nodes with the GPU label and their instance type
kubectl get nodes -l workload-type=gpu \
  -o custom-columns='NAME:.metadata.name,INSTANCE:.metadata.labels.node\.kubernetes\.io/instance-type,STATUS:.status.conditions[-1].type'
```

If the output is empty, the GPU node group has `desiredSize=0`. Scale it up:

```bash
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name gpu \
  --scaling-config desiredSize=1
# Wait for node to become Ready (~3 minutes)
kubectl wait --for=condition=Ready node -l workload-type=gpu --timeout=300s
```

---

## Step 2 — Inspect allocatable GPU resources

```bash
# Show capacity and allocatable for a GPU node
GPU_NODE=$(kubectl get nodes -l workload-type=gpu -o jsonpath='{.items[0].metadata.name}')

kubectl describe node "$GPU_NODE" | grep -A 10 "Allocatable:"
kubectl describe node "$GPU_NODE" | grep -A 10 "Capacity:"
```

Expected output includes:

```
Allocatable:
  nvidia.com/gpu:  1
```

If `nvidia.com/gpu` does not appear, the NVIDIA Device Plugin is not running. Proceed to Step 3 to diagnose.

---

## Step 3 — Inspect the NVIDIA Device Plugin DaemonSet

```bash
# Confirm the device plugin pods are running on GPU nodes
kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds -o wide

# If not present, install via Helm
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update
helm upgrade --install nvidia-device-plugin nvdp/nvidia-device-plugin \
  --namespace kube-system \
  --set tolerations[0].key=nvidia.com/gpu \
  --set tolerations[0].operator=Exists \
  --set tolerations[0].effect=NoSchedule
```

Check device plugin logs if `nvidia.com/gpu` still does not appear:

```bash
PLUGIN_POD=$(kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds \
  -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n kube-system "$PLUGIN_POD"
```

Common failure: the plugin pod cannot start because it lacks a toleration for the GPU node taint.

---

## Step 4 — Run nvidia-smi via a pod

```bash
kubectl apply -f manifests/nvidia-smi-pod.yaml
kubectl wait --for=condition=Ready pod/nvidia-smi --timeout=60s
kubectl logs nvidia-smi
```

Expected output:

```
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 535.x   Driver Version: 535.x   CUDA Version: 12.x                         |
|-------------------------------+----------------------+----------------------------------|
| GPU  Name           ...       | Bus-Id        Disp.A | Volatile Uncorr. ECC            |
|   0  Tesla T4       ...       | 00000000:00:1E.0 Off |                  0              |
```

---

## Step 5 — Verify GPU allocation tracking

```bash
# Check how many GPUs are currently allocated vs available
kubectl describe node "$GPU_NODE" | grep -A 5 "Allocated resources"
```

The `nvidia.com/gpu` line shows `Requests` (allocated) and the allocatable total. A GPU in use by any pod will reduce the available count immediately.

---

## Step 6 — Clean up

```bash
kubectl delete pod nvidia-smi --ignore-not-found
```

---

## Knowledge Check

1. What happens to `nvidia.com/gpu` in a node's allocatable resources if the NVIDIA Device Plugin DaemonSet is not running?
2. A GPU node has `desired_size=1` and the node is `Ready`, but `kubectl describe node` shows no `nvidia.com/gpu` in `Allocatable`. What do you check first?
3. Why are GPU nodes tainted by default?
4. A pod requests `nvidia.com/gpu: 1` but stays `Pending` even though the GPU node shows 1 GPU allocatable. What is likely missing from the pod spec?
5. How do you verify that a GPU is physically accessible inside a running container?

<details>
<summary>Answers</summary>

1. The resource does not appear at all — the node is treated as a CPU-only node by the scheduler and no GPU-requesting pod can be placed on it.
2. Check whether the NVIDIA Device Plugin DaemonSet has a pod running on that node (`kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds -o wide`). If the pod is not present or is in `CrashLoopBackOff`, inspect its logs for driver or permission errors.
3. To prevent general-purpose workloads from consuming GPU capacity unintentionally. Without the taint, any pod without a GPU request could be scheduled onto a GPU node, wasting the expensive resource.
4. A `tolerations` block matching the GPU node taint (`nvidia.com/gpu=present:NoSchedule`). Without it the scheduler skips all GPU nodes.
5. Run `nvidia-smi` inside the container — either via `kubectl exec` into a running pod or by launching a one-shot pod that executes `nvidia-smi` and prints its output to logs.

</details>
