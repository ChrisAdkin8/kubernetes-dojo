# Exercise 03 — Distributed Training

## Learning Objectives

By the end of this exercise you will be able to:

- Run a single-GPU training workload as a Kubernetes Job
- Configure an Indexed Job to distribute work across multiple GPU pods
- Explain how `JOB_COMPLETION_INDEX`, `RANK`, and `WORLD_SIZE` coordinate distributed training
- Monitor Job progress and retrieve per-worker logs

---

## Background

Machine learning training jobs are batch workloads — they run to completion, not indefinitely. Kubernetes Jobs are the correct primitive: they track completion, handle restarts on failure, and clean up pods when done.

### Single-GPU vs distributed training

| Mode | Pods | When to use |
|---|---|---|
| Single-GPU | 1 | Model fits in one GPU's memory; dataset is small |
| Data-parallel (DDP) | N (one per GPU) | Model fits in one GPU; scale throughput by splitting data |
| Model-parallel | N (specialised) | Model is too large for one GPU's memory |

### Indexed Jobs

`spec.completionMode: Indexed` gives each pod a unique index via the environment variable `JOB_COMPLETION_INDEX` (0 to N-1). PyTorch DDP uses this as the process `RANK`:

```
RANK          = JOB_COMPLETION_INDEX
WORLD_SIZE    = spec.completions
MASTER_ADDR   = <pod-0 hostname>
MASTER_PORT   = 29500
```

Each worker connects to the master (rank 0) on `MASTER_PORT` for the initial rendezvous, then all workers communicate directly during training.

### torchrun vs manual RANK injection

`torchrun` (PyTorch's launcher) handles rank assignment automatically when given `--nproc_per_node` and `--nnodes`. For single-node multi-GPU, use `torchrun --nproc_per_node=N`. For multi-node, use the Indexed Job pattern with one pod per node.

---

## Prerequisites

```bash
export CLUSTER_NAME=my-eks-cluster

# Confirm GPU nodes are available
kubectl get nodes -l workload-type=gpu
GPU_COUNT=$(kubectl get nodes -l workload-type=gpu --no-headers | wc -l)
echo "Available GPU nodes: $GPU_COUNT"
```

---

## Step 1 — Run a single-GPU training Job

This Job runs a synthetic PyTorch training loop to confirm the GPU is reachable end-to-end from within a training framework:

```bash
kubectl apply -f manifests/single-gpu-job.yaml

# Watch Job completion
kubectl get job single-gpu-training -w
```

Check the output:

```bash
POD=$(kubectl get pods -l job-name=single-gpu-training -o jsonpath='{.items[0].metadata.name}')
kubectl logs "$POD"
```

Expected output ends with:

```
Epoch 10/10 — loss: 0.0312 — device: cuda:0
Training complete.
```

If `device: cpu` appears, the GPU was not allocated — inspect the pod's resource requests.

---

## Step 2 — Inspect Job status

```bash
kubectl describe job single-gpu-training
```

Key fields to read:

| Field | Meaning |
|---|---|
| `Completions` | Target vs achieved |
| `Parallelism` | Max concurrent pods |
| `Succeeded` | Pods that exited 0 |
| `Failed` | Pods that exited non-zero (triggers retry up to `backoffLimit`) |

---

## Step 3 — Run a distributed Indexed Job

This Job simulates 2-worker distributed training. Each pod logs its rank and the total world size:

```bash
kubectl apply -f manifests/distributed-training-job.yaml

# Watch both pods
kubectl get pods -l job-name=distributed-training -w
```

---

## Step 4 — Retrieve per-worker logs

```bash
# Logs from rank 0 (index 0)
kubectl logs -l job-name=distributed-training,batch.kubernetes.io/job-completion-index=0

# Logs from rank 1 (index 1)
kubectl logs -l job-name=distributed-training,batch.kubernetes.io/job-completion-index=1
```

Each worker should print its rank, world size, and local dataset shard:

```
[rank 0 / world_size 2] processing shard 0 of 2
[rank 1 / world_size 2] processing shard 1 of 2
```

---

## Step 5 — Simulate a worker failure

Edit the distributed Job manifest to introduce a deliberate failure in rank 1 (change the command to `exit 1`), then observe:

```bash
# After applying the broken manifest:
kubectl describe job distributed-training | grep -E "Failed|backoffLimit"
kubectl get events --sort-by='.lastTimestamp' | grep distributed-training
```

The Job retries up to `backoffLimit` times before marking itself `Failed`.

---

## Step 6 — Clean up

```bash
kubectl delete job single-gpu-training distributed-training --ignore-not-found
```

---

## Knowledge Check

1. Why use a Kubernetes Job rather than a Deployment for ML training?
2. What is `JOB_COMPLETION_INDEX` and which DDP variable does it map to?
3. A 2-worker Indexed Job has one pod stuck in `Pending` (insufficient GPU). What happens to the other pod?
4. What does `backoffLimit: 0` mean for a training Job?
5. How would you retrieve logs from all workers of a completed Job in a single command?
6. Your distributed training runs slower with 4 GPUs than with 2. What is the most likely cause?

<details>
<summary>Answers</summary>

1. A Deployment is designed for long-running services that should always be running. A Job tracks completion (exit 0), handles failure retries, and terminates pods when the work is done. Training has a definite end; a Deployment would restart the container after it exits, running training indefinitely.
2. `JOB_COMPLETION_INDEX` is an environment variable injected by Kubernetes into each pod of an Indexed Job, with values 0 to N-1. In PyTorch DDP it maps directly to `RANK` — the unique identity of each process in the distributed group.
3. The running pod will either wait at the rendezvous barrier (if using `torchrun`) and eventually time out, or — if not using a rendezvous — continue and potentially complete its own shard alone. In a proper DDP setup, all workers must reach the rendezvous before any can proceed; a missing worker causes the others to hang until the rendezvous timeout.
4. `backoffLimit: 0` means no retries. If any pod exits non-zero, the Job is immediately marked `Failed`. Use this when training is not idempotent or when you want to inspect the failure state without automatic re-runs.
5. `kubectl logs -l job-name=<name> --prefix` — the `--prefix` flag prepends the pod name to each line so you can distinguish workers. For completed pods you may need `--previous` depending on the pod phase.
6. Communication overhead dominates compute time. As `WORLD_SIZE` increases, the `AllReduce` gradient synchronisation step transfers more data between workers. If the network bandwidth between GPU nodes is insufficient (e.g. nodes are on different racks with no EFA/high-bandwidth interconnect), synchronisation latency grows and GPUs spend more time waiting than computing.

</details>
