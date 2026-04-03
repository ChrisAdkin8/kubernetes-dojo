# Exercise 05 — Persistent Storage

## Learning Objectives

By the end of this exercise you will be able to:

- Create a StorageClass backed by AWS EBS (gp3)
- Create a PersistentVolumeClaim and bind it to a PersistentVolume
- Mount a PVC into a Pod and verify data persists across Pod restarts
- Explain the difference between static and dynamic provisioning
- Describe the volume lifecycle: Pending → Bound → Released → Deleted

---

## Background

Kubernetes storage concepts:

| Object | Role |
|---|---|
| **StorageClass** | Template for dynamically provisioning volumes (defines the provisioner, volume type, encryption, etc.) |
| **PersistentVolume (PV)** | A piece of storage provisioned by an admin or dynamically. Has its own lifecycle, independent of any Pod. |
| **PersistentVolumeClaim (PVC)** | A request for storage by a user. Binds to a PV that satisfies the request. |

### Dynamic vs static provisioning

| Type | How it works |
|---|---|
| **Dynamic** | PVC references a StorageClass → the CSI driver provisions a new volume automatically |
| **Static** | Admin pre-creates PVs and users claim them with matching PVCs |

EKS uses **dynamic** provisioning via the [AWS EBS CSI Driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver), which is included as a managed add-on in this cluster.

### Access modes

| Mode | Abbreviation | EBS support |
|---|---|---|
| `ReadWriteOnce` | RWO | Yes — one node at a time |
| `ReadOnlyMany` | ROX | No |
| `ReadWriteMany` | RWX | No (use EFS CSI driver instead) |

---

## Step 1 — Create the StorageClass

```bash
kubectl apply -f manifests/storage-class.yaml
kubectl get storageclass gp3-encrypted
```

Check if it is set as the default:

```bash
kubectl get storageclass
# Look for (default) next to the name
```

---

## Step 2 — Create the PersistentVolumeClaim

```bash
kubectl apply -f manifests/pvc.yaml
kubectl get pvc app-data
```

The PVC may show `Pending` initially. With `WaitForFirstConsumer` binding mode, the volume is not provisioned until a Pod is scheduled.

---

## Step 3 — Mount the PVC in a Pod

```bash
kubectl apply -f manifests/pod-with-pvc.yaml
```

Watch the Pod start and the PVC bind:

```bash
kubectl get pod pod-with-storage -w
kubectl get pvc app-data
```

Once `Bound`, verify data is written:

```bash
kubectl exec pod-with-storage -- cat /data/timestamp.txt
kubectl exec pod-with-storage -- tail -5 /data/log.txt
```

---

## Step 4 — Verify data persists across Pod restarts

Delete the Pod (not the PVC):

```bash
kubectl delete pod pod-with-storage
```

Re-create it:

```bash
kubectl apply -f manifests/pod-with-pvc.yaml
```

The original timestamp should still be there:

```bash
kubectl exec pod-with-storage -- cat /data/timestamp.txt
```

---

## Step 5 — Inspect the underlying PersistentVolume

```bash
kubectl get pv
kubectl describe pv $(kubectl get pvc app-data -o jsonpath='{.spec.volumeName}')
```

The PV's `Claim` field shows which PVC it is bound to. The `Source` section shows the EBS volume ID.

---

## Step 6 — Understand reclaim policies

The `reclaimPolicy: Delete` in the StorageClass means the EBS volume is **deleted when the PVC is deleted**. Other options:

| Policy | Behaviour |
|---|---|
| `Delete` | PV and the backing storage are deleted when the PVC is deleted |
| `Retain` | PV and storage are kept; admin must manually reclaim |
| `Recycle` | Deprecated — scrubs the volume and makes it available again |

---

## Step 7 — Clean up

```bash
kubectl delete -f manifests/
# This deletes the PVC → which triggers deletion of the PV → which deletes the EBS volume
```

Verify the volume is gone:

```bash
kubectl get pv
```

---

## Knowledge Check

1. A PVC is stuck in `Pending`. What are the three most common causes?
2. What is the difference between `WaitForFirstConsumer` and `Immediate` volume binding modes?
3. A developer deletes a PVC. The StorageClass has `reclaimPolicy: Retain`. What happens to the data?
4. You need a volume that can be mounted by 10 Pods simultaneously. Can you use an EBS volume? What would you use instead?
5. After a Pod restart, a developer notices the log file starts from zero. What did they forget?

<details>
<summary>Answers</summary>

1. (a) No StorageClass matches the requested class name. (b) The storage capacity requested exceeds what any available PV offers. (c) The access mode requested is not supported by the provisioner.
2. `WaitForFirstConsumer` delays provisioning until a Pod claiming the PVC is scheduled — this ensures the volume is created in the correct AZ. `Immediate` provisions the volume as soon as the PVC is created, which can result in zone mismatches.
3. The PV transitions to `Released` state and is NOT deleted. The data is preserved on the EBS volume. An admin must manually delete the PV and reclaim the storage.
4. No — EBS only supports `ReadWriteOnce`. Use the [AWS EFS CSI Driver](https://github.com/kubernetes-sigs/aws-efs-csi-driver) with `ReadWriteMany`.
5. They mounted an `emptyDir` instead of a PVC. `emptyDir` is ephemeral and is deleted when the Pod is deleted.

</details>
