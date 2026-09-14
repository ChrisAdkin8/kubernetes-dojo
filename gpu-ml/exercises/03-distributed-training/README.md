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

`spec.completionMode: Indexed` gives each pod a unique index via the environment variable `JOB_COMPLETION_INDEX` (0 to N-1), and the hostname `<job-name>-<index>`. With a headless Service of the same name as the pod's `subdomain`, each pod gets a DNS name, so pod 0 can act as the rendezvous master:

```
--node-rank   = JOB_COMPLETION_INDEX                          (torchrun then sets RANK)
--nnodes      = spec.completions                              (WORLD_SIZE = nnodes × nproc-per-node)
--master-addr = distributed-training-0.distributed-training   (pod 0, through the headless Service)
--master-port = 29500
```

Each worker connects to the master (rank 0) on the master port for the initial rendezvous, then all workers communicate directly during training.

### torchrun

`torchrun` (PyTorch's launcher) starts `--nproc-per-node` processes on each node and sets `RANK`, `LOCAL_RANK`, `WORLD_SIZE`, `MASTER_ADDR` and `MASTER_PORT` for each one, so the training script doesn't compute them itself. For single-node multi-GPU, use `torchrun --nproc-per-node=N`. For multi-node, run one pod per node, as this exercise's Indexed Job does, and give each pod's torchrun its node rank.

---

## Prerequisites

```bash
export CLUSTER_NAME=$(terraform -chdir="$(git rev-parse --show-toplevel)/eks" output -raw cluster_name)

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

This runs real 2-worker data-parallel training with PyTorch DistributedDataParallel (DDP). The manifest has three parts: a headless Service that gives each worker a DNS name, a ConfigMap with the training script, and an Indexed Job with two pods, each running `torchrun`. The script joins a process group (NCCL on GPU), wraps a small model in DDP, gives each rank half of a synthetic dataset with `DistributedSampler`, and trains for 5 epochs. Every `backward()` all-reduces the gradients between the two pods.

Each pod requests a whole GPU, so you need two GPU nodes. Scale the GPU node group to 2 first; this doubles the hourly GPU cost (about $1.23/hour for two g4dn.xlarge), so scale back down when you finish (Step 6):

```bash
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name gpu \
  --scaling-config desiredSize=2
kubectl wait --for=condition=Ready node -l workload-type=gpu --timeout=600s
kubectl get nodes -l workload-type=gpu
```

Then start the Job:

```bash
kubectl apply -f manifests/distributed-training-job.yaml

# Watch both pods. The first pull of the PyTorch image takes a few minutes.
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

Each worker prints its backend, rank and world size, and rank 0 prints the loss after each epoch, averaged over both workers (you may also see some of torchrun's own log lines). Rank 0:

```
backend=nccl rank=0 world_size=2 device=cuda:0
epoch 1 loss 0.8008
epoch 2 loss 0.0108
epoch 3 loss 0.0099
epoch 4 loss 0.0099
epoch 5 loss 0.0099
```

Rank 1:

```
backend=nccl rank=1 world_size=2 device=cuda:0
```

The loss falls because both workers compute gradients on their own half of the data and DDP averages them before every optimiser step. Your numbers may differ slightly.

---

## Step 5 — Simulate a worker failure

Make rank 1 fail before it starts training. Delete the finished Job, then edit `manifests/distributed-training-job.yaml` and add this line at the start of the container's `args` script, before `exec torchrun`:

```sh
[ "$JOB_COMPLETION_INDEX" = "1" ] && exit 1
```

Apply it and observe:

```bash
kubectl delete job distributed-training
kubectl apply -f manifests/distributed-training-job.yaml
kubectl get pods -l job-name=distributed-training -w
```

Rank 1 exits with an error straight away, and the kubelet restarts it (`restartPolicy: OnFailure`). Each restart counts towards `backoffLimit: 2`, so within about half a minute the Job controller marks the Job failed with `BackoffLimitExceeded` and deletes both pods. Rank 0 never trained: it was waiting at the rendezvous for rank 1 the whole time. In DDP, one worker's failure stops the whole job.

A worker that never starts at all is different, for example one stuck `Pending` because there's no second GPU node. Nothing fails, so nothing counts towards `backoffLimit`: rank 0 waits at the rendezvous until torchrun gives up (after 10 minutes by default with `--master-addr`), exits and is restarted to wait again, until `activeDeadlineSeconds: 1200` ends the Job with `DeadlineExceeded`. That's the hang knowledge-check answer 3 describes.

```bash
kubectl describe job distributed-training | grep -E "Failed|backoffLimit|DeadlineExceeded|BackoffLimitExceeded"
kubectl get events --sort-by='.lastTimestamp' | grep distributed-training
```

Undo the edit afterwards with `git checkout -- manifests/distributed-training-job.yaml`.

---

## Step 6 — Clean up

```bash
kubectl delete job single-gpu-training --ignore-not-found
kubectl delete -f manifests/distributed-training-job.yaml --ignore-not-found

# Scale the GPU node group back to 0
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name gpu \
  --scaling-config desiredSize=0
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
2. `JOB_COMPLETION_INDEX` is an environment variable injected by Kubernetes into each pod of an Indexed Job, with values 0 to N-1. With one process per pod, it is the node rank you pass to `torchrun --node-rank`, and so the process's `RANK` — the unique identity of each process in the distributed group. (With several processes per pod, `RANK = node rank × nproc-per-node + LOCAL_RANK`.)
3. The running pod will either wait at the rendezvous barrier (if using `torchrun`) and eventually time out, or — if not using a rendezvous — continue and potentially complete its own shard alone. In a proper DDP setup, all workers must reach the rendezvous before any can proceed; a missing worker causes the others to hang until the rendezvous timeout.
4. `backoffLimit: 0` means no retries. If any pod exits non-zero, the Job is immediately marked `Failed`. Use this when training is not idempotent or when you want to inspect the failure state without automatic re-runs.
5. `kubectl logs -l job-name=<name> --prefix` — the `--prefix` flag prepends the pod name to each line so you can distinguish workers. For completed pods you may need `--previous` depending on the pod phase.
6. Communication overhead dominates compute time. As `WORLD_SIZE` increases, the `AllReduce` gradient synchronisation step transfers more data between workers. If the network bandwidth between GPU nodes is insufficient (e.g. nodes are on different racks with no EFA/high-bandwidth interconnect), synchronisation latency grows and GPUs spend more time waiting than computing.

</details>
