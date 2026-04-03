# Exercise 01 — Pods and Containers

## Learning Objectives

By the end of this exercise you will be able to:

- Create, inspect, and delete a Pod from a manifest
- Execute commands inside a running container
- Read container logs (current and previous runs)
- Describe the lifecycle phases a Pod moves through
- Explain the purpose of init containers and sidecars

---

## Background

A **Pod** is the smallest deployable unit in Kubernetes. It wraps one or more containers that share:

- The same network namespace (same IP, same port space)
- The same set of volumes
- The same lifecycle

Most workloads use one container per Pod. Multi-container Pods are used for specific patterns:

| Pattern | Purpose |
|---|---|
| **Init container** | Runs to completion before the main containers start. Common for setup, migrations, waiting on dependencies. |
| **Sidecar** | Runs alongside the main container for the duration of the Pod. Common for log shippers, service mesh proxies, metrics exporters. |
| **Ambassador** | Proxies network traffic on behalf of the main container. |
| **Adapter** | Transforms the main container's output into a standard format. |

---

## Step 1 — Create a simple Pod

```bash
kubectl apply -f manifests/nginx-pod.yaml
```

Check that it reached the `Running` phase:

```bash
kubectl get pod nginx-pod
```

Expected output:
```
NAME        READY   STATUS    RESTARTS   AGE
nginx-pod   1/1     Running   0          10s
```

**What each column means:**

| Column | Meaning |
|---|---|
| `READY` | `<running containers>/<total containers>` |
| `STATUS` | Current phase (Pending → Running → Succeeded/Failed) |
| `RESTARTS` | How many times the container has been restarted |

---

## Step 2 — Inspect the Pod

Get detailed information including events, IP address, and container state:

```bash
kubectl describe pod nginx-pod
```

Key sections to read:

- **Node** — which worker node the Pod is scheduled on
- **IP** — the Pod's cluster-internal IP
- **Containers** — image, ports, resource requests/limits, probe status
- **Events** — scheduling decisions, image pulls, container starts

---

## Step 3 — Execute a command inside the container

Open an interactive shell:

```bash
kubectl exec -it nginx-pod -- /bin/sh
```

From inside the container, run:

```sh
# Verify the web server is listening
wget -qO- localhost
# Exit
exit
```

Run a one-off command without an interactive shell:

```bash
kubectl exec nginx-pod -- cat /etc/nginx/nginx.conf
```

---

## Step 4 — View container logs

```bash
# Stream live logs (ctrl+c to stop)
kubectl logs -f nginx-pod

# Show only the last 20 lines
kubectl logs nginx-pod --tail=20

# Show logs with timestamps
kubectl logs nginx-pod --timestamps
```

---

## Step 5 — Create a multi-container Pod

```bash
kubectl apply -f manifests/multi-container-pod.yaml
```

Watch the Pod move through init → running:

```bash
kubectl get pod multi-container-pod -w
```

Once running, view logs from each container by name:

```bash
# Main app container
kubectl logs multi-container-pod -c app

# Sidecar container
kubectl logs multi-container-pod -c log-sidecar
```

Exec into the sidecar and verify it can see the shared volume:

```bash
kubectl exec -it multi-container-pod -c log-sidecar -- /bin/sh
ls /shared
cat /shared/message.txt
exit
```

---

## Step 6 — Understand Pod phases

Delete and re-create the Pod and watch the phase transitions:

```bash
kubectl delete pod nginx-pod
kubectl apply -f manifests/nginx-pod.yaml
kubectl get pod nginx-pod -w
```

The five Pod phases:

| Phase | Meaning |
|---|---|
| `Pending` | Accepted by the API server; not yet scheduled or pulled |
| `Running` | At least one container is running |
| `Succeeded` | All containers exited with code 0 (batch workloads) |
| `Failed` | At least one container exited non-zero or was killed |
| `Unknown` | Cannot communicate with the node |

---

## Step 7 — Clean up

```bash
kubectl delete -f manifests/
```

---

## Knowledge Check

Answer these questions without looking at the manifests:

1. What command would you use to open a shell in a container named `app` inside a Pod named `my-pod`?
2. A Pod has two containers. How do you view logs from just the second container?
3. What is the difference between a `livenessProbe` and a `readinessProbe`?
4. A Pod is stuck in `Pending`. What is the first command you run and what are you looking for?
5. What does `READY: 0/2` mean on a Pod?
6. When would you use an init container instead of a sidecar?

<details>
<summary>Answers</summary>

1. `kubectl exec -it my-pod -c app -- /bin/sh`
2. `kubectl logs my-pod -c <container-name>`
3. **liveness**: if it fails, the container is killed and restarted. **readiness**: if it fails, the Pod is removed from Service endpoints but not restarted.
4. `kubectl describe pod <name>` — look at the **Events** section for scheduling failures (insufficient CPU/memory, no matching nodes).
5. Two containers in the Pod; zero are currently passing their readiness check.
6. When you need setup to complete *before* the main container starts (e.g. wait for a database, write config files). Sidecars run concurrently.

</details>
