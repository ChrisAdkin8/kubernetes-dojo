# Exercise 07 — Scheduling

## Learning Objectives

By the end of this exercise you will be able to:

- Use `nodeSelector` to constrain a Pod to labelled nodes
- Write `nodeAffinity` rules (required and preferred)
- Write `podAffinity` and `podAntiAffinity` rules for co-location and spreading
- Apply taints to nodes and add tolerations to Pods
- Explain how the kube-scheduler makes placement decisions

---

## Background

The **kube-scheduler** assigns each Pod to a node through two phases:

1. **Filtering** — eliminates nodes that cannot run the Pod (insufficient resources, failing predicates, taints without matching tolerations).
2. **Scoring** — ranks the remaining nodes and picks the highest scorer.

You influence scheduling with:

| Mechanism | Granularity | Flexibility |
|---|---|---|
| `nodeSelector` | Simple label match | Low |
| `nodeAffinity` | Expression-based node matching | Medium |
| `podAffinity` / `podAntiAffinity` | Place relative to other Pods | Medium |
| Taints & tolerations | Mark nodes as "repellent" | High |
| `topologySpreadConstraints` | Distribute Pods evenly | High |

---

## Step 1 — Label a node

```bash
# List current node labels
kubectl get nodes --show-labels

# Apply a custom label
kubectl label node $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') workload=compute

# Verify
kubectl get node $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') --show-labels
```

---

## Step 2 — nodeSelector

```bash
kubectl apply -f manifests/node-selector.yaml
kubectl get pod node-selector-pod -o wide
```

The `NODE` column should show the labelled node.

Remove the label and watch the Pod become unschedulable if it is recreated:

```bash
kubectl label node $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') workload-
kubectl delete pod node-selector-pod
kubectl apply -f manifests/node-selector.yaml
kubectl describe pod node-selector-pod | grep -A5 Events
```

Clean up:

```bash
kubectl delete pod node-selector-pod
kubectl label node $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') workload=compute
```

---

## Step 3 — Node and Pod affinity

```bash
kubectl apply -f manifests/affinity.yaml
kubectl get pods -l app=affinity-demo -o wide
```

Inspect the placement — all Pods should be on `amd64` nodes, and spread across hosts when possible.

Check the affinity rules took effect:

```bash
kubectl describe pod -l app=affinity-demo | grep -A10 "Node-Selectors\|Tolerations\|Affinity"
```

---

## Step 4 — Taints and tolerations

Taint the first node:

```bash
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl taint node $NODE dedicated=gpu:NoSchedule
kubectl describe node $NODE | grep Taints
```

Create a Pod **without** the toleration — it should not schedule on the tainted node:

```bash
kubectl run no-toleration --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl get pod no-toleration -o wide
```

Create the Pod **with** the toleration:

```bash
kubectl apply -f manifests/taints-tolerations.yaml
kubectl get pod tolerating-pod -o wide
```

The tolerating Pod can schedule on either node; the untolerating Pod avoids the tainted node.

Remove the taint:

```bash
kubectl taint node $NODE dedicated=gpu:NoSchedule-
```

---

## Step 5 — topologySpreadConstraints (bonus)

Spread Pods evenly across zones:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-demo
spec:
  replicas: 4
  selector:
    matchLabels:
      app: spread-demo
  template:
    metadata:
      labels:
        app: spread-demo
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: spread-demo
      containers:
        - name: app
          image: nginx:1.27-alpine
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"
EOF
```

Check placement across zones:

```bash
kubectl get pods -l app=spread-demo -o wide
```

---

## Step 6 — Clean up

```bash
kubectl delete -f manifests/
kubectl delete deployment spread-demo --ignore-not-found
kubectl delete pod no-toleration --ignore-not-found
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl label node $NODE workload-
```

---

## Knowledge Check

1. What is the difference between `requiredDuringSchedulingIgnoredDuringExecution` and `preferredDuringSchedulingIgnoredDuringExecution`?
2. A Pod has `podAntiAffinity` set to spread across `kubernetes.io/hostname`. You have 3 nodes and 5 replicas. What happens?
3. What are the three taint effects and when would you use each?
4. A critical monitoring DaemonSet must run on every node, including tainted nodes. How do you achieve this?
5. What does `IgnoredDuringExecution` mean in affinity terms?

<details>
<summary>Answers</summary>

1. `required` is a hard constraint — the Pod will not schedule if no node matches. `preferred` is a soft constraint — the scheduler tries to satisfy it but will place the Pod elsewhere if necessary.
2. With `preferredDuringSchedulingIgnoredDuringExecution` (soft anti-affinity), the extra two Pods will still schedule on already-used nodes. With `requiredDuringSchedulingIgnoredDuringExecution` (hard), the 4th and 5th Pods would be `Pending` until new nodes are available.
3. `NoSchedule` — new Pods without the toleration will not be scheduled on the node (existing Pods unaffected). `PreferNoSchedule` — soft version; scheduler avoids the node but may use it. `NoExecute` — new Pods without the toleration will not schedule, and existing Pods without the toleration are evicted (with optional grace period via `tolerationSeconds`).
4. Add a toleration for every taint the nodes could have, or add a wildcard toleration: `key: ""`, `operator: Exists`, `effect: ""` (matches all taints).
5. If the constraints are violated after the Pod is running (e.g. a node's label changes), the Pod is not evicted. The constraint is only enforced at scheduling time. `IgnoredDuringExecution` is the current default; `RequiredDuringExecution` (which would evict violating Pods) is planned but not yet implemented as of Kubernetes 1.31.

</details>
