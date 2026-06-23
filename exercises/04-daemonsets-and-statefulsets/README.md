# Exercise 04 — DaemonSets and StatefulSets

## Learning Objectives

By the end of this exercise you will be able to:

- Explain when to use a DaemonSet instead of a Deployment
- Deploy a DaemonSet and verify it runs on every node
- Explain the guarantees a StatefulSet provides over a Deployment
- Deploy a StatefulSet with persistent storage and a headless Service
- Describe the ordered startup, scaling, and deletion behaviour of StatefulSets

---

## Background

Kubernetes offers several workload controllers. Exercise 03 covered **Deployments** — the default choice for stateless applications. This exercise introduces two more:

### DaemonSet

A **DaemonSet** ensures that **exactly one copy** of a Pod runs on every node (or a subset of nodes selected by `nodeSelector` / `affinity`). When nodes join the cluster the DaemonSet controller automatically schedules a Pod; when nodes leave, the Pod is garbage-collected.

| Use case | Example |
|---|---|
| Log collection | Fluent Bit, Fluentd, Logstash |
| Node monitoring | Prometheus Node Exporter, Datadog agent |
| Networking | kube-proxy, Calico, Cilium |
| Storage drivers | CSI node plugins |

### StatefulSet

A **StatefulSet** manages Pods that need **stable identity** and **persistent storage**. Unlike a Deployment, it provides:

| Guarantee | Description |
|---|---|
| Stable network identity | Each Pod gets a predictable DNS name: `<pod-name>.<service-name>.<namespace>.svc.cluster.local` |
| Ordered startup and shutdown | Pods are created in order (0, 1, 2 …) and terminated in reverse order |
| Stable persistent storage | Each Pod gets its own PersistentVolumeClaim via `volumeClaimTemplates`; PVCs survive Pod rescheduling |

A StatefulSet requires a **headless Service** (`clusterIP: None`) so that each Pod gets its own DNS A record.

```
StatefulSet "web" + headless Service "web"
  ├── web-0  →  web-0.web.default.svc.cluster.local  →  PVC data-web-0
  ├── web-1  →  web-1.web.default.svc.cluster.local  →  PVC data-web-1
  └── web-2  →  web-2.web.default.svc.cluster.local  →  PVC data-web-2
```

### DaemonSet vs Deployment vs StatefulSet

| Feature | Deployment | DaemonSet | StatefulSet |
|---|---|---|---|
| Replica count | User-defined | One per node (automatic) | User-defined |
| Pod identity | Interchangeable | Interchangeable | Stable, ordered |
| Storage | Shared or none | Host paths typical | Per-Pod PVC |
| Typical use | Stateless services | Node-level agents | Databases, message queues |

---

## Step 1 — Deploy the DaemonSet

```bash
kubectl apply -f manifests/daemonset.yaml
```

Watch the Pods roll out — one should appear per node:

```bash
kubectl get daemonset log-collector
kubectl get pods -l app=log-collector -o wide
```

Compare the Pod count with the node count:

```bash
kubectl get nodes --no-headers | wc -l
kubectl get pods -l app=log-collector --no-headers | wc -l
```

The numbers should match (or differ by the number of tainted nodes your DaemonSet does not tolerate).

---

## Step 2 — Inspect DaemonSet scheduling

Check which nodes received a Pod:

```bash
kubectl get pods -l app=log-collector -o wide
```

The `NODE` column shows the placement. Unlike a Deployment, you cannot scale a DaemonSet — the cluster topology determines the replica count.

View the DaemonSet status fields:

```bash
kubectl get daemonset log-collector -o yaml | grep -A5 status
```

Key fields: `desiredNumberScheduled`, `currentNumberScheduled`, `numberReady`.

---

## Step 3 — Deploy the StatefulSet

The StatefulSet manifest includes a headless Service (`clusterIP: None`) and a `volumeClaimTemplate`:

```bash
kubectl apply -f manifests/statefulset.yaml
```

Watch Pods start **in order** — `web-0` must be Ready before `web-1` starts:

```bash
kubectl get pods -l app=web -w
```

---

## Step 4 — Verify stable identity

Each Pod has a predictable hostname:

```bash
kubectl exec web-0 -- hostname
kubectl exec web-1 -- hostname
kubectl exec web-2 -- hostname
```

Each Pod has a DNS A record via the headless Service:

```bash
kubectl run dns-test --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup web-0.web.default.svc.cluster.local
```

---

## Step 5 — Verify persistent storage

Write unique data to each Pod's volume:

```bash
for i in 0 1 2; do
  kubectl exec web-$i -- sh -c "echo 'Hello from web-$i' > /usr/share/nginx/html/index.html"
done
```

Delete a Pod and watch the StatefulSet recreate it with the **same name** and **same PVC**:

```bash
kubectl delete pod web-1
kubectl get pods -l app=web -w
```

Once `web-1` is back, verify the data survived:

```bash
kubectl exec web-1 -- cat /usr/share/nginx/html/index.html
```

You should see `Hello from web-1` — the data persisted because the PVC was reattached.

---

## Step 6 — Ordered scaling

Scale the StatefulSet down and observe reverse-order termination:

```bash
kubectl scale statefulset web --replicas=1
kubectl get pods -l app=web -w
```

`web-2` terminates first, then `web-1`. Scale back up:

```bash
kubectl scale statefulset web --replicas=3
kubectl get pods -l app=web -w
```

Pods start in order again. The PVCs are still present, so the data is restored.

---

## Step 7 — Clean up

```bash
kubectl delete -f manifests/
# PVCs from volumeClaimTemplates are NOT deleted automatically
kubectl delete pvc -l app=web
```

---

## Knowledge Check

1. You need to run a security agent on every node including the control plane. Which controller do you use, and what must you add to the Pod spec?
2. What happens when a new node joins the cluster and a DaemonSet is already running?
3. A StatefulSet has 3 replicas. `web-1` is stuck in `Pending`. Will `web-2` start?
4. You delete a StatefulSet with `kubectl delete statefulset web`. What happens to the PVCs?
5. Why does a StatefulSet require a headless Service?
6. You change the container image in a DaemonSet. How does the update roll out by default?

<details>
<summary>Answers</summary>

1. A **DaemonSet**. Add a `toleration` for `node-role.kubernetes.io/control-plane` with `effect: NoSchedule` so the Pod is scheduled on tainted control-plane nodes.
2. The DaemonSet controller automatically schedules a Pod on the new node — no manual intervention needed.
3. No. StatefulSets enforce ordered startup by default (`podManagementPolicy: OrderedReady`). `web-2` waits until `web-1` is Running and Ready. To allow parallel startup, set `podManagementPolicy: Parallel`.
4. The PVCs are **retained**. Kubernetes does not delete PVCs created by `volumeClaimTemplates` when the StatefulSet is deleted, to prevent accidental data loss. You must delete them manually.
5. A headless Service (`clusterIP: None`) creates individual DNS A records for each Pod (e.g. `web-0.web.default.svc.cluster.local`). A regular ClusterIP Service would round-robin across Pods, which defeats the purpose of stable identity.
6. DaemonSets use a `RollingUpdate` strategy by default (since Kubernetes 1.6). Pods are updated one node at a time. You can tune `maxUnavailable` to control how many nodes update simultaneously.

</details>
