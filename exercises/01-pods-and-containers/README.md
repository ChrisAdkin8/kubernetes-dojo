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

You will see the `log-sidecar` container enter `CrashLoopBackOff`. Continue to Step 6 to diagnose and fix it.

---

## Step 6 — Troubleshoot a CrashLoopBackOff

`CrashLoopBackOff` means a container keeps exiting and Kubernetes keeps restarting it with exponential back-off (10s → 20s → 40s … up to 5 min).

### 6.1 — Confirm which container is crashing

```bash
kubectl get pod multi-container-pod
```

Expected output (note `READY: 1/2` — the `app` container is healthy, the sidecar is not):

```
NAME                  READY   STATUS             RESTARTS   AGE
multi-container-pod   1/2     CrashLoopBackOff   3          90s
```

### 6.2 — Read the events

```bash
kubectl describe pod multi-container-pod
```

Scroll to the **Events** section at the bottom. You will see repeated `Back-off restarting failed container log-sidecar` entries. The **Containers** section will show the sidecar's last exit code.

### 6.3 — Read the container logs

For a crashed container, grab logs from the *previous* run with `--previous` (`-p`):

```bash
kubectl logs multi-container-pod -c log-sidecar --previous
```

You will see:

```
touch: /var/log/access.log: No such file or directory
```

**Root cause:** `busybox:1.36` is a minimal image — `/var/log/` does not exist. The `touch` command fails, the shell exits non-zero, and Kubernetes restarts the container in a loop.

### 6.4 — Fix the manifest

Open `manifests/multi-container-pod.yaml` and change the sidecar `args` block from:

```yaml
args:
  - |
    touch /var/log/access.log
    tail -f /var/log/access.log
```

to:

```yaml
args:
  - |
    mkdir -p /var/log
    touch /var/log/access.log
    tail -f /var/log/access.log
```

### 6.5 — Re-apply and verify

Delete the broken Pod and re-apply the corrected manifest:

```bash
kubectl delete pod multi-container-pod
kubectl apply -f manifests/multi-container-pod.yaml
kubectl get pod multi-container-pod -w
```

Expected output once stable:

```
NAME                  READY   STATUS    RESTARTS   AGE
multi-container-pod   2/2     Running   0          15s
```

Now both containers are healthy. View logs from each:

```bash
# Main app container
kubectl logs multi-container-pod -c app

# Sidecar container
kubectl logs multi-container-pod -c log-sidecar
```

Exec into the sidecar and verify the shared volume:

```bash
kubectl exec -it multi-container-pod -c log-sidecar -- /bin/sh
ls /shared
cat /shared/message.txt
exit
```

**CrashLoopBackOff diagnostic checklist:**

| Step | Command | What you are looking for |
|---|---|---|
| 1 | `kubectl get pod <name>` | Which container shows `CrashLoopBackOff`; READY ratio |
| 2 | `kubectl describe pod <name>` | Exit code in **Containers** section; scheduling/pull errors in **Events** |
| 3 | `kubectl logs <name> -c <container> --previous` | Last stdout/stderr before crash |
| 4 | Fix the root cause | Bad command, missing file/dir, wrong image, resource OOM |
| 5 | Delete and re-apply | Confirm `READY` ratio goes to `<n>/<n>` |

---

## Step 8 — Understand Pod phases

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

## Step 9 — Clean up

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
7. A container is in `CrashLoopBackOff` and `kubectl logs` returns no output. How do you get the logs from the last crash?
8. A Pod shows `READY: 1/2` and `STATUS: CrashLoopBackOff`. Which container is crashing — and how do you tell?

<details>
<summary>Answers</summary>

1. `kubectl exec -it my-pod -c app -- /bin/sh`
2. `kubectl logs my-pod -c <container-name>`
3. **liveness**: if it fails, the container is killed and restarted. **readiness**: if it fails, the Pod is removed from Service endpoints but not restarted.
4. `kubectl describe pod <name>` — look at the **Events** section for scheduling failures (insufficient CPU/memory, no matching nodes).
5. Two containers in the Pod; zero are currently passing their readiness check.
6. When you need setup to complete *before* the main container starts (e.g. wait for a database, write config files). Sidecars run concurrently.
7. `kubectl logs <pod> -c <container> --previous` — the `--previous` flag fetches logs from the terminated instance rather than the newly started (and possibly not yet crashed) one.
8. `kubectl get pod <name>` shows the READY ratio (e.g. `1/2` means one of the two is healthy). `kubectl describe pod <name>` lists each container's last exit code under **Containers** — the one with a non-zero exit code is the crasher.

</details>
