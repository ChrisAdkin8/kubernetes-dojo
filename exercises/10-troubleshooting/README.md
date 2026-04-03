# Exercise 10 — Troubleshooting

## Learning Objectives

By the end of this exercise you will be able to:

- Diagnose and explain `CrashLoopBackOff`, `OOMKilled`, and `ImagePullBackOff`
- Use `kubectl describe`, `kubectl logs`, and `kubectl events` to root-cause issues
- Debug networking and DNS problems from inside a cluster
- Interpret `kubectl top` output and connect it to resource limits
- Follow a systematic debugging methodology

---

## Background

### Systematic debugging methodology

When a workload is not behaving as expected:

1. **Locate** — `kubectl get pods` / `kubectl get events --sort-by='.lastTimestamp'`
2. **Describe** — `kubectl describe pod <name>` → read the Events section
3. **Logs** — `kubectl logs <name>` + `kubectl logs <name> --previous`
4. **Exec** — `kubectl exec -it <name> -- /bin/sh` for interactive inspection
5. **Network** — test connectivity with a temporary debug Pod
6. **Resources** — `kubectl top pod` / `kubectl top node`

### Common failure states

| State | Meaning | First thing to check |
|---|---|---|
| `Pending` | Not scheduled yet | `kubectl describe pod` → Events section |
| `CrashLoopBackOff` | Container keeps crashing | `kubectl logs --previous` |
| `OOMKilled` | Memory limit exceeded | `kubectl describe pod` → Last State |
| `ImagePullBackOff` | Cannot pull container image | `kubectl describe pod` → Events |
| `CreateContainerConfigError` | Bad ConfigMap/Secret reference | `kubectl describe pod` → Events |
| `RunContainerError` | Container start error (bad command, etc.) | `kubectl describe pod` → Events |
| `Terminating` (stuck) | Finalizer blocking deletion | `kubectl get pod -o yaml | grep finalizers` |

---

## Step 1 — CrashLoopBackOff

```bash
kubectl apply -f manifests/crashloopbackoff-pod.yaml
```

Watch it crash:

```bash
kubectl get pod crash-pod -w
```

Read the exit logs:

```bash
kubectl logs crash-pod
kubectl logs crash-pod --previous   # logs from the crashed run
```

Describe the Pod to see the restart count and exit code:

```bash
kubectl describe pod crash-pod
```

In the `Last State` section, look for `Exit Code: 1`.

**Common exit codes:**

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | General application error |
| `2` | Misuse of shell built-in |
| `127` | Command not found |
| `128+N` | Fatal signal N (e.g. `137` = SIGKILL / OOMKill) |
| `137` | Process killed (OOM or manual kill) |
| `143` | SIGTERM (graceful shutdown requested) |

---

## Step 2 — OOMKilled

```bash
kubectl apply -f manifests/oomkilled-pod.yaml
```

Watch the kill:

```bash
kubectl get pod oom-pod -w
```

Inspect the Last State:

```bash
kubectl describe pod oom-pod | grep -A10 "Last State"
```

You will see `Reason: OOMKilled` and `Exit Code: 137`.

---

## Step 3 — ImagePullBackOff

```bash
kubectl apply -f manifests/imagepullbackoff-pod.yaml
kubectl describe pod imgpull-pod | grep -A15 Events
```

The Events section will contain something like:

```
Failed to pull image "nginx:this-tag-does-not-exist-99999": ... 404 Not Found
```

**Common causes:**

1. Wrong image name or tag
2. Private registry without imagePullSecrets
3. ECR image in a different account or region
4. Rate limiting from Docker Hub

---

## Step 4 — Debug networking

Start a temporary debug Pod with useful networking tools:

```bash
kubectl run netdebug \
  --image=nicolaka/netshoot \
  --restart=Never \
  -it --rm \
  -- /bin/bash
```

From inside the debug Pod:

```bash
# DNS resolution
nslookup kubernetes.default.svc.cluster.local
dig @10.96.0.10 web-app-clusterip.default.svc.cluster.local

# HTTP connectivity
curl -v http://web-app-clusterip/

# TCP port check
nc -zv web-app-clusterip 80

# Trace routing
traceroute 8.8.8.8

# Check name resolution
cat /etc/resolv.conf
```

---

## Step 5 — Resource diagnostics

View resource usage (requires Metrics Server):

```bash
# By Pod
kubectl top pods

# By node
kubectl top nodes

# Find the most CPU-hungry Pod
kubectl top pods --sort-by=cpu --all-namespaces | head -10
```

---

## Step 6 — Event investigation

Get all events in the cluster sorted by time:

```bash
kubectl get events --sort-by='.lastTimestamp' --all-namespaces
```

Filter for warning events only:

```bash
kubectl get events --field-selector type=Warning --all-namespaces
```

---

## Step 7 — Stuck finalizer (bonus)

Create a Pod with a finalizer that will cause it to get stuck on deletion:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: finalizer-pod
  finalizers:
    - example.com/my-finalizer
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: "10m"
          memory: "16Mi"
        limits:
          cpu: "50m"
          memory: "64Mi"
EOF
```

Delete the Pod and watch it get stuck:

```bash
kubectl delete pod finalizer-pod
kubectl get pod finalizer-pod
# It will show Terminating indefinitely
```

Force-remove the finalizer to unblock deletion:

```bash
kubectl patch pod finalizer-pod -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl get pod finalizer-pod
```

---

## Step 8 — Clean up

```bash
kubectl delete -f manifests/
kubectl delete pod netdebug --ignore-not-found
kubectl delete pod finalizer-pod --ignore-not-found
```

---

## Knowledge Check

1. A Pod shows `READY: 0/1` and `STATUS: Running`. What does this tell you and how do you investigate?
2. A Deployment rollout is stuck. `kubectl rollout status` hangs. What do you do?
3. A container's memory limit is 256Mi but the process only uses 100Mi. It still gets OOMKilled. Why could this happen?
4. You exec into a Pod and cannot reach `google.com` but can reach other cluster Services. What is likely wrong?
5. Walk through how you would debug a Pod that is stuck in `Pending` for 10 minutes.

<details>
<summary>Answers</summary>

1. The container is running but failing its readiness probe. It is excluded from Service Endpoints and receiving no traffic. Investigate with: `kubectl describe pod <name>` → look at the Readiness probe section and Recent Events. Also check `kubectl logs <name>` for application startup errors.
2. `kubectl get pods -l <selector> -o wide` to see which Pods are unhealthy. `kubectl describe pod <stuck-pod>` to read events. Check if new Pods are stuck in `Pending` (resource quota, unschedulable) or `CrashLoopBackOff` (bad image/config). Use `kubectl rollout pause/undo` to stop the rollout and roll back.
3. The memory limit applies to the container's cgroup. The process may have spawned child processes or threads that collectively exceed 256Mi, or a JVM/runtime may have allocated heap beyond the visible RSS. Use `kubectl exec` and `cat /sys/fs/cgroup/memory/memory.usage_in_bytes` to see actual cgroup usage.
4. The Pod likely has a NetworkPolicy blocking egress to external IPs, or the node's NAT gateway / internet gateway is missing. DNS should still work (it's internal). Test with `curl -v https://1.1.1.1` to rule out DNS issues. Check `kubectl get networkpolicy -n <namespace>`.
5. `kubectl describe pod <name>` → Events section. Look for: (a) "Insufficient cpu/memory" → node capacity exhausted, scale the node group. (b) "0/N nodes are available: N node(s) had taints the pod didn't tolerate" → add tolerations or remove taints. (c) "didn't match node selector" → fix nodeSelector or label the nodes. (d) "PVC not bound" → check PVC status. (e) "unbound immediate PersistentVolumeClaims" → PVC still Pending.

</details>
