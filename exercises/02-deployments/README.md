# Exercise 02 — Deployments

## Learning Objectives

By the end of this exercise you will be able to:

- Create and inspect a Deployment
- Scale a Deployment up and down
- Trigger a rolling update and watch it progress
- Roll back to a previous revision
- Explain the relationship between Deployment → ReplicaSet → Pod

---

## Background

A **Deployment** manages a set of identical Pods via a **ReplicaSet**. You declare the desired state (image, replica count, update strategy) and the Deployment controller continuously reconciles actual state toward it.

```
Deployment
  └── ReplicaSet (current revision)
        ├── Pod
        ├── Pod
        └── Pod
```

When you update the image, the Deployment creates a **new** ReplicaSet and gradually shifts traffic to it (rolling update), keeping the old ReplicaSet around so you can roll back.

### Deployment strategy types

The `spec.strategy.type` field controls how the Deployment transitions from the old version to the new one.

| Strategy | Behaviour | Downtime | Use case |
|---|---|---|---|
| `RollingUpdate` (default) | Replaces Pods incrementally — new ones start before old ones stop | None (if tuned correctly) | Production services that must stay available |
| `Recreate` | Terminates all existing Pods before creating any new ones | Yes — gap between old down and new up | Dev/test, or workloads that cannot run two versions simultaneously (e.g. exclusive DB migrations) |

#### RollingUpdate tuning parameters

```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1   # max Pods that can be unavailable at any point
      maxSurge: 1         # max extra Pods above desired count during rollout
```

Both values accept an integer (absolute count) or a percentage of `spec.replicas`.

| `maxUnavailable` | `maxSurge` | Effect |
|---|---|---|
| `0` | `1` | Always full capacity — one new Pod starts before any old Pod stops. Slowest, safest. |
| `1` | `0` | Constant replica count — one old Pod stops before one new one starts. No extra capacity needed. |
| `25%` | `25%` | Default. Balanced speed and availability. |
| `100%` | `0` | All Pods replaced simultaneously — equivalent to `Recreate` with a brief overlap if surge > 0. |

#### Recreate

```yaml
spec:
  strategy:
    type: Recreate
```

No additional parameters. All running Pods are terminated (scaled to 0) before any new Pods are created. Choose this when two versions of the application cannot safely run at the same time — for example, if the new version applies a database schema migration that the old version cannot read.

---

## Step 1 — Create the Deployment

```bash
kubectl apply -f manifests/deployment.yaml
```

Watch the rollout:

```bash
kubectl rollout status deployment/web-app
```

Inspect what was created:

```bash
# See the Deployment
kubectl get deployment web-app

# See the ReplicaSets (there will be one)
kubectl get replicaset -l app=web-app

# See the Pods
kubectl get pods -l app=web-app
```

---

## Step 2 — Scale the Deployment

Scale to 5 replicas imperatively:

```bash
kubectl scale deployment web-app --replicas=5
kubectl get pods -l app=web-app -w
```

Scale back to 3:

```bash
kubectl scale deployment web-app --replicas=3
```

You can also edit the `replicas` field in the manifest and re-apply — that is the preferred, declarative approach.

---

## Step 3 — Trigger a rolling update

Update the image to a newer tag:

```bash
kubectl set image deployment/web-app web=nginx:1.26-alpine
```

Watch the rollout in real time:

```bash
kubectl rollout status deployment/web-app
```

While rolling, run the following in another terminal to see old and new Pods coexist:

```bash
kubectl get pods -l app=web-app -w
```

After the rollout, inspect the ReplicaSets — there should now be two:

```bash
kubectl get replicaset -l app=web-app
```

The old ReplicaSet is kept with 0 replicas so you can roll back.

---

## Step 4 — Inspect rollout history

```bash
kubectl rollout history deployment/web-app
```

View the details of a specific revision:

```bash
kubectl rollout history deployment/web-app --revision=1
```

> **Tip:** Add `--record` to `kubectl apply`/`set image` commands to capture the change cause. In newer Kubernetes versions, use the `kubernetes.io/change-cause` annotation on the Deployment instead.

---

## Step 5 — Roll back

Roll back to the previous revision (revision 1):

```bash
kubectl rollout undo deployment/web-app
```

Roll back to a specific revision:

```bash
kubectl rollout undo deployment/web-app --to-revision=1
```

Verify the image is back:

```bash
kubectl describe deployment web-app | grep Image
```

---

## Step 6 — Pause and resume a rollout

Pause mid-rollout to inspect state before continuing:

```bash
kubectl rollout pause deployment/web-app
kubectl set image deployment/web-app web=nginx:1.27-alpine
# The rollout will not proceed while paused
kubectl rollout resume deployment/web-app
```

---

## Step 7 — Clean up

```bash
kubectl delete -f manifests/
```

---

## Knowledge Check

1. You have a Deployment with 3 replicas. After `kubectl delete pod <one-of-the-pods>`, what happens?
2. What is the difference between `maxUnavailable` and `maxSurge` in a `RollingUpdate` strategy?
3. A rolling update is stuck — Pods are in `Pending`. What do you check first?
4. Why does Kubernetes keep the old ReplicaSet after a successful rolling update?
5. What is the declarative equivalent of `kubectl scale deployment web-app --replicas=5`?
6. When would you choose `Recreate` over `RollingUpdate`?
7. A Deployment has `maxUnavailable: 0` and `maxSurge: 1` with 4 replicas. How many Pods will exist at peak during a rolling update, and why?

<details>
<summary>Answers</summary>

1. The ReplicaSet controller immediately creates a replacement Pod to maintain the desired replica count.
2. `maxUnavailable`: how many Pods can be unavailable during the update. `maxSurge`: how many *extra* Pods above the desired count can exist during the update.
3. `kubectl describe pod <pending-pod>` — look at Events for resource constraints or unschedulable reasons.
4. To enable rollback. `kubectl rollout undo` scales the old ReplicaSet back up and scales the new one down.
5. Edit `spec.replicas` in the manifest and run `kubectl apply -f deployment.yaml`.
6. When two versions of the application cannot safely run simultaneously — for example, if the new version applies a breaking database schema migration that the old version cannot read, or if the application holds an exclusive lock (e.g. a file, port, or singleton resource) that prevents a second instance from starting.
7. 5 Pods — `maxSurge: 1` allows one extra Pod above the desired 4, so the new ReplicaSet starts one new Pod before any old Pod is terminated. `maxUnavailable: 0` prevents any Pod from being removed until the new one is `Ready`, so at peak there are 4 old + 1 new = 5 running simultaneously.

</details>
