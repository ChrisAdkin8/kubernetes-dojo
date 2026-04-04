# Exercise 06 — Storage for ML Workloads

## Learning Objectives

By the end of this exercise you will be able to:

- Explain the storage access patterns of ML training workloads
- Provision an EFS-backed PersistentVolume with ReadWriteMany access
- Mount shared storage in multiple pods simultaneously for dataset access
- Implement a checkpoint write-and-read pattern to survive pod restarts

---

## Background

ML workloads have storage needs that differ from typical stateless services:

### Access patterns

| Pattern | Description | Storage type |
|---|---|---|
| Shared dataset reads | Many pods read the same training data concurrently | EFS (RWX) |
| Model checkpoint writes | Periodic writes to survive pod failure mid-training | EFS or S3 |
| Node-local scratch | Extremely fast ephemeral reads/writes during a single epoch | `emptyDir` (node NVMe) |
| Model weight serving | One pod reads a large file at startup, holds it in GPU memory | EBS or EFS (ROX/RWX) |

### Why ReadWriteMany (RWX) matters

gp3 EBS volumes are `ReadWriteOnce` (RWO) — they can only be mounted by one node at a time. For distributed training with N pods on N nodes, each pod needs to read the same dataset. EFS provides `ReadWriteMany` (RWX) access, allowing all pods to mount the same volume simultaneously.

### Checkpoint strategy

Without checkpointing, a training job that runs for 10 hours and fails at hour 9 must restart from scratch. Checkpointing saves model weights and optimiser state to durable storage at regular intervals. On pod restart, training resumes from the last checkpoint.

```
Epoch 1 → Epoch 10 → checkpoint saved → pod fails
Epoch 11 → resumes from checkpoint at epoch 10 → completes
```

### EFS CSI Driver

The EFS CSI driver (`efs.csi.aws.com`) is the Kubernetes integration for Amazon EFS. It provisions `PersistentVolumeClaims` backed by EFS access points, which scope each PVC to a subdirectory on the file system with independent ownership and permissions.

---

## Prerequisites

```bash
export CLUSTER_NAME=my-eks-cluster
export AWS_REGION=eu-west-2

# Confirm EFS CSI driver is installed
kubectl get pods -n kube-system -l app=efs-csi-node -o wide

# If not present, install it:
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver
helm repo update
helm upgrade --install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
  --namespace kube-system

# Retrieve your EFS file system ID (created separately via Terraform or console)
EFS_ID=$(aws efs describe-file-systems \
  --query "FileSystems[?Tags[?Key=='cluster'&&Value=='${CLUSTER_NAME}']].FileSystemId | [0]" \
  --output text)
echo "EFS ID: $EFS_ID"
```

---

## Step 1 — Create a StorageClass and PVC for shared dataset access

```bash
# Edit manifests/efs-storageclass.yaml and set the fileSystemId
sed -i "s/EFS_ID_PLACEHOLDER/${EFS_ID}/" manifests/efs-storageclass.yaml

kubectl apply -f manifests/efs-storageclass.yaml
kubectl apply -f manifests/efs-pvc.yaml

# Confirm PVC is Bound
kubectl get pvc shared-dataset
```

The PVC status should show `Bound` within a few seconds. If it stays `Pending`, check EFS CSI driver logs:

```bash
kubectl logs -n kube-system -l app=efs-csi-controller -c efs-plugin
```

---

## Step 2 — Write a dataset to the shared volume

```bash
kubectl apply -f manifests/dataset-writer-pod.yaml
kubectl wait --for=condition=Ready pod/dataset-writer --timeout=60s

# Confirm the dataset was written
kubectl exec dataset-writer -- ls -lh /data/
kubectl exec dataset-writer -- cat /data/dataset-info.txt
```

---

## Step 3 — Read the dataset from a second pod simultaneously

The dataset-writer pod is still running (holding the RWX mount). Apply the reader:

```bash
kubectl apply -f manifests/dataset-reader-pod.yaml
kubectl wait --for=condition=Ready pod/dataset-reader --timeout=60s

# Both pods have the volume mounted at the same time
kubectl exec dataset-reader -- cat /data/dataset-info.txt
kubectl exec dataset-reader -- ls -lh /data/
```

Both pods can read concurrently because EFS supports RWX. Try the same with a gp3 EBS PVC to observe the `Multi-Attach error`.

---

## Step 4 — Write and recover a checkpoint

```bash
# Write a simulated checkpoint from the writer pod
kubectl exec dataset-writer -- python3 -c "
import json, time, os
os.makedirs('/data/checkpoints', exist_ok=True)
checkpoint = {'epoch': 5, 'loss': 0.312, 'timestamp': time.time()}
with open('/data/checkpoints/checkpoint-epoch-5.json', 'w') as f:
    json.dump(checkpoint, f)
print('Checkpoint saved.')
"

# Simulate pod failure by deleting the writer
kubectl delete pod dataset-writer

# Recover from checkpoint in a new pod
kubectl apply -f manifests/dataset-writer-pod.yaml
kubectl wait --for=condition=Ready pod/dataset-writer --timeout=60s

kubectl exec dataset-writer -- python3 -c "
import json, glob
checkpoints = sorted(glob.glob('/data/checkpoints/checkpoint-epoch-*.json'))
if checkpoints:
    with open(checkpoints[-1]) as f:
        ckpt = json.load(f)
    print(f'Resuming from epoch {ckpt[\"epoch\"]} (loss: {ckpt[\"loss\"]})')
else:
    print('No checkpoint found — starting from epoch 0')
"
```

---

## Step 5 — Measure EFS throughput

```bash
# Write throughput test (sequential 1 GB write)
kubectl exec dataset-writer -- bash -c "
  dd if=/dev/zero of=/data/throughput-test bs=1M count=1024 conv=fdatasync 2>&1 | tail -1
"

# Read throughput test
kubectl exec dataset-writer -- bash -c "
  dd if=/data/throughput-test of=/dev/null bs=1M 2>&1 | tail -1
"
```

EFS General Purpose mode delivers ~100 MB/s sequential throughput per file system in the default burst mode. For sustained high-throughput workloads, consider EFS Provisioned Throughput.

---

## Step 6 — Clean up

```bash
kubectl delete pod dataset-writer dataset-reader --ignore-not-found
kubectl delete pvc shared-dataset --ignore-not-found
kubectl delete storageclass efs-ml --ignore-not-found
```

---

## Knowledge Check

1. Why can a gp3 EBS volume not be mounted by two training pods on different nodes simultaneously?
2. A distributed training Job with 4 workers is stuck because only the first pod can mount the dataset volume. What access mode does the PVC need?
3. What is the risk of checkpointing to an `emptyDir` volume?
4. A model checkpoint is 8 GB. Saving it to EFS at the end of every epoch adds 80 seconds per epoch. How would you reduce this overhead without losing checkpoint safety?
5. The EFS PVC is `Pending`. The EFS file system exists and is tagged correctly. What is the most likely cause?

<details>
<summary>Answers</summary>

1. EBS volumes use the `ReadWriteOnce` (RWO) access mode, which restricts mounting to a single node at a time. If two pods on different nodes try to use the same EBS PVC, the second mount will fail with a `Multi-Attach` error.
2. `ReadWriteMany` (RWX). EFS with the EFS CSI driver supports RWX, allowing all four worker pods on separate nodes to mount the same PVC concurrently.
3. `emptyDir` is tied to the pod's lifetime on a node. If the pod is evicted, rescheduled to a different node, or the node fails, the `emptyDir` and any checkpoints in it are lost. Training restarts from scratch.
4. Save only the diff (changed weight tensors) rather than the full model state, or checkpoint asynchronously in a background thread/process while training continues. Another option is to checkpoint every N epochs rather than every epoch, accepting a longer maximum rollback window.
5. The EFS CSI driver is not installed, or the StorageClass `fileSystemId` parameter does not match the actual EFS file system ID, or the EFS security group does not allow NFS (port 2049) inbound from the node security group.

</details>
