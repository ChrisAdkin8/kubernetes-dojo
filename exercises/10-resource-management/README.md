# Exercise 10 — Resource Management

## Learning Objectives

By the end of this exercise you will be able to:

- Set CPU and memory `requests` and `limits` on containers
- Explain the three QoS classes and when each applies
- Create a ResourceQuota to cap namespace resource usage
- Create a LimitRange to set default container limits
- Configure a HorizontalPodAutoscaler and understand its scaling behaviour

---

## Background

### Requests vs Limits

| Field | Purpose | Enforcement |
|---|---|---|
| `requests` | Minimum guaranteed resources; used by the scheduler for placement | Node reservation — scheduler only places the Pod if the node has this much available |
| `limits` | Maximum resources the container may use | CPU is throttled at the limit; memory over-limit causes OOMKill |

### QoS Classes

The kubelet assigns a QoS class based on requests and limits:

| Class | Condition | Eviction priority |
|---|---|---|
| `Guaranteed` | Every container has equal `requests` == `limits` for CPU and memory | Last to be evicted |
| `Burstable` | At least one container has `requests` < `limits` | Medium priority |
| `BestEffort` | No container has any `requests` or `limits` | First to be evicted |

---

## Prerequisites

The HorizontalPodAutoscaler in Step 5 (and `kubectl top` in exercise 12) needs the Metrics Server. Check whether it's installed:

```bash
kubectl get deployment metrics-server -n kube-system
```

If not, install a pinned release and wait for it:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s
kubectl top nodes
```

If `kubectl top nodes` returns `error: Metrics API not available`, wait 60 seconds for the first scrape and try again.

---

## Step 1 — Observe QoS classes

Create a Guaranteed Pod:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: guaranteed-pod
spec:
  containers:
    - name: app
      image: nginx:1.27-alpine
      resources:
        requests:
          cpu: "100m"
          memory: "128Mi"
        limits:
          cpu: "100m"
          memory: "128Mi"
EOF
```

Check its QoS class:

```bash
kubectl get pod guaranteed-pod -o jsonpath='{.status.qosClass}'
```

Create a BestEffort Pod and check its class:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: besteffort-pod
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sleep", "3600"]
EOF
kubectl get pod besteffort-pod -o jsonpath='{.status.qosClass}'
```

Clean up these test Pods before continuing:

```bash
kubectl delete pod guaranteed-pod besteffort-pod
```

---

## Step 2 — Apply ResourceQuota and LimitRange

```bash
kubectl apply -f manifests/resource-quota.yaml
```

This creates the `team-alpha` namespace, a ResourceQuota, and a LimitRange.

Inspect them:

```bash
kubectl describe resourcequota team-alpha-quota -n team-alpha
kubectl describe limitrange team-alpha-limits -n team-alpha
```

---

## Step 3 — Test the LimitRange defaults

Create a Pod in `team-alpha` without any resource specifications:

```bash
cat <<'EOF' | kubectl apply -n team-alpha -f -
apiVersion: v1
kind: Pod
metadata:
  name: default-limits-pod
spec:
  containers:
    - name: app
      image: nginx:1.27-alpine
EOF
```

The LimitRange should have injected default requests and limits:

```bash
kubectl get pod default-limits-pod -n team-alpha -o jsonpath='{.spec.containers[0].resources}' | python3 -m json.tool
```

---

## Step 4 — Test the ResourceQuota

Check current usage:

```bash
kubectl describe resourcequota team-alpha-quota -n team-alpha
```

Try to exceed the quota by creating more Pods than allowed:

```bash
for i in $(seq 1 25); do
  kubectl run pod-$i --image=busybox:1.36 --restart=Never -n team-alpha -- sleep 3600 2>&1
done
kubectl get pods -n team-alpha | wc -l
```

You should see `Error from server (Forbidden)` for Pods beyond the limit of 20.

---

## Step 5 — HorizontalPodAutoscaler

First deploy the target Deployment (from exercise 03), and the ClusterIP Service from exercise 05 that the load generator sends requests to (exercise 05's clean-up deletes it):

```bash
kubectl apply -f ../03-deployments/manifests/deployment.yaml
kubectl apply -f ../05-services/manifests/clusterip-service.yaml
kubectl apply -f manifests/hpa.yaml
```

Inspect the HPA:

```bash
kubectl get hpa web-app-hpa
kubectl describe hpa web-app-hpa
```

Generate some CPU load to trigger scale-up. One request loop isn't enough to push three nginx Pods past 70% of their 50m CPU request, so this runs four loops in parallel:

```bash
kubectl run load-generator \
  --image=busybox:1.36 \
  --restart=Never \
  -- /bin/sh -c "for i in 1 2 3 4; do (while true; do wget -q -O- http://web-app-clusterip >/dev/null; done) & done; wait"
```

Watch the HPA scale up the Deployment (takes ~1 minute):

```bash
kubectl get hpa web-app-hpa -w
```

Stop the load and watch it scale down:

```bash
kubectl delete pod load-generator
kubectl get hpa web-app-hpa -w
```

---

## Step 6 — Clean up

```bash
kubectl delete -f manifests/
kubectl delete -f ../03-deployments/manifests/
kubectl delete -f ../05-services/manifests/clusterip-service.yaml
kubectl delete namespace team-alpha
kubectl delete pod load-generator --ignore-not-found
```

---

## Knowledge Check

1. A container's CPU usage hits its limit. What happens?
2. A container's memory usage exceeds its limit. What happens?
3. You have a Pod with `requests.cpu=100m` and `limits.cpu=500m`. What QoS class is it?
4. Why should production Pods always set `requests` and `limits`?
5. An HPA is configured with `minReplicas=2`, `maxReplicas=10`, target CPU 70%. Current CPU is 35%. How many replicas will the HPA converge to?

<details>
<summary>Answers</summary>

1. The container is CPU-throttled — it continues running but cannot use more CPU than the limit. No restart occurs.
2. The kernel OOM killer terminates the container. Kubernetes restarts it (CrashLoopBackOff if it happens repeatedly). The Pod's status will show `OOMKilled`.
3. `Burstable` — it has requests != limits.
4. Without `requests`, the scheduler cannot make informed placement decisions, leading to overcommitted nodes. Without `limits`, a runaway container can starve other workloads. Both are required for the pod to receive a `Guaranteed` QoS class.
5. The HPA formula is: `desiredReplicas = ceil(currentReplicas × (currentMetric / targetMetric))`. At 35% CPU with target 70%: `ceil(2 × (35/70)) = ceil(1) = 1`. However, since `minReplicas=2`, it will maintain 2 replicas.

</details>
