# Exercise 02 — GPU Scheduling

## Learning Objectives

By the end of this exercise you will be able to:

- Write a pod spec that correctly requests a GPU
- Explain why GPU resource requests must equal their limits
- Diagnose scheduling failures caused by missing tolerations or insufficient capacity
- Confirm GPU exclusivity — that a GPU allocated to one pod is unavailable to others

---

## Background

GPU scheduling in Kubernetes differs from CPU and memory in three important ways:

### Requests must equal limits

CPU and memory support overcommit — you can request less than the limit. GPUs cannot be overcommitted. The scheduler enforces:

- You must set **both** `requests` and `limits` to the same integer value
- A request of `0` with a limit of `1` is rejected
- Fractional values (e.g. `0.5`) are rejected unless GPU time-slicing is configured on the node

### GPUs are exclusively allocated

Once a pod is scheduled onto a GPU, no other pod can use that GPU until the first pod terminates. There is no sharing at the Kubernetes resource level (without time-slicing or MIG).

### Tolerations are required for tainted GPU nodes

If GPU nodes carry the standard taint `nvidia.com/gpu=present:NoSchedule`, every GPU-requesting pod must include a matching toleration, or the scheduler will skip all GPU nodes and the pod will remain `Pending`.

### Scheduling decision flow

| Check | Passes if... |
|---|---|
| Taint toleration | Pod has matching `toleration` |
| Node selector / affinity | Node labels match pod's `nodeSelector` or `affinity` |
| GPU capacity | Node has enough free `nvidia.com/gpu` |
| Other resources | Sufficient CPU and memory remain |

All checks must pass; a failure at any step blocks scheduling.

---

## Prerequisites

```bash
export CLUSTER_NAME=my-eks-cluster
export AWS_REGION=eu-west-2

GPU_NODE=$(kubectl get nodes -l workload-type=gpu -o jsonpath='{.items[0].metadata.name}')
echo "GPU node: $GPU_NODE"

# Confirm a GPU is available
kubectl describe node "$GPU_NODE" | grep "nvidia.com/gpu"
```

---

## Step 1 — Schedule a GPU pod

```bash
kubectl apply -f manifests/gpu-pod.yaml

# Watch it become Running
kubectl get pod gpu-workload -w
```

Once `Running`, confirm it landed on the GPU node:

```bash
kubectl get pod gpu-workload -o wide
```

The `NODE` column should match `$GPU_NODE`.

---

## Step 2 — Verify GPU allocation is reflected on the node

```bash
kubectl describe node "$GPU_NODE" | grep -A 8 "Allocated resources"
```

The `nvidia.com/gpu` row will show `1` request against the node's total. While `gpu-workload` is running, no other pod can claim that GPU.

---

## Step 3 — Attempt to schedule without a toleration

```bash
kubectl apply -f manifests/no-toleration-pod.yaml

# This pod should stay Pending
kubectl get pod gpu-no-toleration -w
```

Inspect why:

```bash
kubectl describe pod gpu-no-toleration | grep -A 5 "Events:"
```

Expected event:

```
Warning  FailedScheduling  ... 0/N nodes are available: N node(s) had untolerated taint {nvidia.com/gpu: present}.
```

---

## Step 4 — Attempt to over-request GPU capacity

With `gpu-workload` still running (holding the only GPU), try to schedule a second GPU pod:

```bash
kubectl apply -f manifests/gpu-pod-2.yaml

kubectl describe pod gpu-workload-2 | grep -A 5 "Events:"
```

Expected event:

```
Warning  FailedScheduling  ... Insufficient nvidia.com/gpu
```

This confirms exclusivity — the GPU is fully committed to the first pod.

---

## Step 5 — Release the GPU and observe rescheduling

```bash
kubectl delete pod gpu-workload

# gpu-workload-2 should now schedule within seconds
kubectl get pod gpu-workload-2 -w
```

Once `gpu-workload-2` is `Running`, confirm the GPU is now allocated to it:

```bash
kubectl describe node "$GPU_NODE" | grep -A 8 "Allocated resources"
```

---

## Step 6 — Clean up

```bash
kubectl delete pod gpu-workload gpu-workload-2 gpu-no-toleration --ignore-not-found
```

---

## Knowledge Check

1. What happens if you set `resources.requests.nvidia.com/gpu: 0` and `resources.limits.nvidia.com/gpu: 1`?
2. Two pods each request `nvidia.com/gpu: 1`. The node has 1 GPU. Pod A schedules first. What is Pod B's status and why?
3. A pod spec has `nvidia.com/gpu: 1` in limits but no `tolerations`. The GPU node has the standard taint. Describe exactly what the scheduler does.
4. You delete the running pod holding the GPU. How quickly does the GPU become available to the pending pod?
5. Can two containers in the same pod each request `nvidia.com/gpu: 1` on a node with 2 GPUs?

<details>
<summary>Answers</summary>

1. The request is invalid and the pod will be rejected by the API server (or the scheduler will refuse it). GPU requests and limits must match; a request of `0` with a non-zero limit is treated as if no GPU was requested, but the limit still prevents scheduling since limits alone without matching requests violate GPU admission.
2. Pod B stays in `Pending` with a `FailedScheduling` event indicating `Insufficient nvidia.com/gpu`. The GPU is exclusively held by Pod A until it terminates.
3. The scheduler evaluates all nodes. GPU nodes have the taint `nvidia.com/gpu=present:NoSchedule`. Since the pod has no matching toleration, those nodes are filtered out immediately. Non-GPU nodes have no GPU capacity. The pod stays `Pending` indefinitely with the event `0/N nodes are available: N node(s) had untolerated taint`.
4. Nearly immediately — within one scheduler cycle (typically under 5 seconds). Once the kubelet reports the pod has terminated, the node's allocatable GPU count returns to 1 and the scheduler places the pending pod.
5. Yes — if the node has 2 GPUs, both containers in a single pod can each request 1 GPU. The pod will be allocated both GPUs and each container will have exclusive access to its own.

</details>
