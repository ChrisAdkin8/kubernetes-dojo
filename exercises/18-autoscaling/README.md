# Exercise 18 — Autoscaling: HPA, VPA, and Cluster Autoscaler

## Learning Objectives

By the end of this exercise you will be able to:

- Configure a HorizontalPodAutoscaler (HPA) with CPU, memory, and behavior policies
- Explain the HPA scaling formula and predict replica counts at a given load
- Install the VerticalPodAutoscaler (VPA) and read its recommendations
- Describe the three VPA update modes and choose the right one for a workload
- Deploy the Cluster Autoscaler on EKS and explain how it interacts with Auto Scaling Groups
- Distinguish when to use HPA, VPA, and CA — and when to combine them

---

## Background

Kubernetes provides three complementary autoscalers that operate at different levels:

| Autoscaler | What it scales | Metric source | Kubernetes object |
|---|---|---|---|
| **HPA** — Horizontal Pod Autoscaler | Pod replica count | Metrics Server (CPU/mem) or custom metrics | `HorizontalPodAutoscaler` |
| **VPA** — Vertical Pod Autoscaler | Pod resource requests and limits | Historical usage from Metrics Server | `VerticalPodAutoscaler` |
| **CA** — Cluster Autoscaler | Node count (EC2 instances via ASG) | Pending pods and underutilized nodes | Deployment in `kube-system` |

### When to use each

- **HPA**: stateless workloads where more replicas handle more traffic. Requires the application to scale horizontally (no shared in-memory state, no distributed locks).
- **VPA**: workloads where the right replica count is fixed but the right CPU/memory allocation is unknown — for example, a batch job, a singleton controller, or any workload that cannot scale horizontally.
- **CA**: needed whenever HPA adds replicas that cannot schedule because nodes are full, or during off-hours when the cluster should shrink to reduce cost.

> **Can you use HPA and VPA together?** Only with care. Avoid running both in `Auto` mode on the same CPU/memory metrics — VPA changing `requests` re-triggers HPA, causing feedback loops. Use HPA on CPU/memory and VPA on memory-only (or vice versa), or use VPA in `Off` mode for recommendations while HPA handles scaling.

### HPA scaling formula

```
desiredReplicas = ceil(currentReplicas × (currentMetricValue / desiredMetricValue))
```

Example: 4 replicas at 80% CPU, target 50%:
```
ceil(4 × (80 / 50)) = ceil(6.4) = 7
```

The HPA evaluates all configured metrics and scales to satisfy the most demanding one.

### VPA update modes

| Mode | Behaviour |
|---|---|
| `Off` | Computes recommendations only. No pods are evicted or modified. |
| `Initial` | Applies recommendations to new pods only (at admission time). Running pods are not touched. |
| `Auto` | Evicts pods whose requests are outside the recommended range and recreates them with updated requests. |

### Cluster Autoscaler mechanics

1. The CA watches for **Pending** pods — pods that cannot schedule because no node has sufficient resources.
2. It simulates which node groups could accommodate the pending pods and picks the group based on the configured **expander** (default: `random`; `least-waste` is generally better).
3. It calls the AWS Auto Scaling API to increase the ASG `DesiredCapacity`.
4. After the new node registers and the pods schedule, the CA continues watching.
5. For scale-down, it identifies nodes where all pods could be moved to other nodes. After a configurable delay (default 10 minutes) it cordons and drains the node, then decrements the ASG.

---

## Prerequisites

### Metrics Server

The Metrics Server is required by both HPA and VPA. Check whether it is installed:

```bash
kubectl get deployment metrics-server -n kube-system
```

If not present, install it:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

Verify it is running and responding:

```bash
kubectl top nodes
kubectl top pods -A
```

If `kubectl top` returns `error: Metrics API not available`, wait 60 seconds for the Metrics Server to collect its first scrape.

### VPA components (for Steps 5–7)

The VPA requires three components: **recommender**, **updater**, and **admission-controller**. Install via the official installer:

```bash
git clone https://github.com/kubernetes/autoscaler.git /tmp/autoscaler
cd /tmp/autoscaler/vertical-pod-autoscaler
./hack/vpa-up.sh
```

Verify all three pods are running:

```bash
kubectl get pods -n kube-system | grep vpa
```

Expected:

```
vpa-admission-controller-...   1/1   Running
vpa-recommender-...            1/1   Running
vpa-updater-...                1/1   Running
```

---

## Part 1 — Horizontal Pod Autoscaler (HPA)

### Step 1 — Deploy the target workload

The `php-apache` image serves HTTP requests and burns CPU when hit. It is the standard load target from the Kubernetes HPA documentation.

```bash
kubectl apply -f manifests/target-deployment.yaml
```

Wait for the pod to be ready:

```bash
kubectl rollout status deployment/php-apache
kubectl get pods -l app=php-apache
```

### Step 2 — Create the HPA

```bash
kubectl apply -f manifests/hpa.yaml
```

Inspect the HPA immediately:

```bash
kubectl get hpa php-apache
```

Initial output:

```
NAME         REFERENCE               TARGETS          MINPODS   MAXPODS   REPLICAS   AGE
php-apache   Deployment/php-apache   cpu: 0%/50%      1         10        1          10s
```

> **Note:** `<unknown>/50%` means the Metrics Server has not yet collected a sample for this pod. Wait 60 seconds and re-run.

Describe the HPA for the full picture:

```bash
kubectl describe hpa php-apache
```

The `Conditions` section shows whether the HPA is `AbleToScale` and `ScalingActive`. The `Events` section shows every scale decision with its reason.

### Step 3 — Trigger scale-up with load

In a separate terminal, run a load generator:

```bash
kubectl run load-generator \
  --image=busybox:1.36 \
  --restart=Never \
  -- /bin/sh -c "while true; do wget -q -O- http://php-apache; done"
```

Watch the HPA react (takes ~1–2 minutes for the first scale event):

```bash
kubectl get hpa php-apache -w
```

You should see CPU climb above 50%, then `REPLICAS` increase. The formula at 200% CPU with target 50%:
```
ceil(1 × (200 / 50)) = ceil(4) = 4
```

Watch the new pods start:

```bash
kubectl get pods -l app=php-apache -w
```

### Step 4 — Observe scale-down

Stop the load generator:

```bash
kubectl delete pod load-generator
```

The HPA will not scale down immediately — the `stabilizationWindowSeconds: 300` in the `scaleDown` behavior prevents thrashing. Watch the CPU fall and replicas reduce over the next 5 minutes:

```bash
kubectl get hpa php-apache -w
```

This delay is intentional: a 5-minute cooldown avoids yo-yo scaling after a short traffic burst.

### Step 5 — Examine the behavior policy

The HPA in `manifests/hpa.yaml` uses two scale-up policies:

```yaml
scaleUp:
  policies:
    - type: Percent
      value: 100
      periodSeconds: 15   # Can double replica count every 15 seconds
    - type: Pods
      value: 4
      periodSeconds: 15   # Can add 4 pods every 15 seconds
  selectPolicy: Max       # Use whichever adds more pods
```

`selectPolicy: Max` selects the more aggressive policy. For 1 replica: 100% = 1 more pod, 4 pods = 4 more pods — so it adds 4. For 10 replicas: 100% = 10 more pods, 4 pods = 4 more pods — so it doubles.

Change `selectPolicy` to `Min` and observe how scale-up becomes more conservative:

```bash
kubectl patch hpa php-apache --type=merge -p '
{"spec":{"behavior":{"scaleUp":{"selectPolicy":"Min"}}}}'
```

Rerun the load generator and compare how quickly replicas increase.

Restore the original policy:

```bash
kubectl apply -f manifests/hpa.yaml
```

---

## Part 2 — Vertical Pod Autoscaler (VPA)

### Step 6 — Create the VPA in Off mode

The VPA in `manifests/vpa.yaml` starts with `updateMode: Off` — it only observes and recommends, never evicting pods.

```bash
kubectl apply -f manifests/vpa.yaml
```

Wait a few minutes for the recommender to collect data, then read its output:

```bash
kubectl describe vpa php-apache-vpa
```

Look for the `Recommendation` section:

```
Recommendation:
  Container Recommendations:
    Container Name:  php-apache
    Lower Bound:
      Cpu:     25m
      Memory:  262144k
    Target:
      Cpu:     100m
      Memory:  262144k
    Uncapped Target:
      Cpu:     62m
      Memory:  262144k
    Upper Bound:
      Cpu:     1
      Memory:  2Gi
```

| Field | Meaning |
|---|---|
| `Target` | What VPA recommends setting as the container's requests |
| `Lower Bound` | Minimum safe value; going below risks OOMKill or CPU starvation |
| `Upper Bound` | Maximum the VPA would recommend (based on the `maxAllowed` policy) |
| `Uncapped Target` | What VPA would recommend if no `minAllowed`/`maxAllowed` constraints existed |

### Step 7 — Switch VPA to Initial mode

`Initial` mode applies recommendations to new pods at creation time but does not evict running pods:

```bash
kubectl patch vpa php-apache-vpa --type=merge -p '
{"spec":{"updatePolicy":{"updateMode":"Initial"}}}'
```

Delete the current pod to force a new one with the recommended requests:

```bash
kubectl rollout restart deployment/php-apache
```

Inspect the new pod's resources — they should reflect the VPA's target:

```bash
kubectl get pod -l app=php-apache -o jsonpath='{.items[0].spec.containers[0].resources}' | python3 -m json.tool
```

### Step 8 — Switch VPA to Auto mode

`Auto` mode evicts out-of-range pods and recreates them with updated requests. This is appropriate for workloads that can tolerate brief restarts.

```bash
kubectl patch vpa php-apache-vpa --type=merge -p '
{"spec":{"updatePolicy":{"updateMode":"Auto"}}}'
```

Generate load for several minutes (reuse the load generator from Step 3), then stop it. After the recommender updates its model, the updater will evict the pod if its current requests deviate too much from the recommendation. Watch for evictions:

```bash
kubectl get events --field-selector reason=EvictedByVPA --sort-by='.lastTimestamp'
```

> **Warning:** Do not run HPA and VPA in `Auto` mode on the same metrics simultaneously. Reset the HPA to avoid conflicts:
> ```bash
> kubectl delete hpa php-apache
> ```

### Step 9 — Restore VPA to Off mode

```bash
kubectl patch vpa php-apache-vpa --type=merge -p '
{"spec":{"updatePolicy":{"updateMode":"Off"}}}'
```

---

## Part 3 — Cluster Autoscaler (CA)

### Step 10 — IAM setup

The Cluster Autoscaler needs permission to describe and modify Auto Scaling Groups. Create an IAM policy and role via the AWS CLI:

```bash
# Capture cluster details from Terraform output
CLUSTER_NAME=$(cd ../../eks && terraform output -raw cluster_name)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_PROVIDER=$(aws eks describe-cluster --name "$CLUSTER_NAME" \
  --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')

# Create the IAM policy
aws iam create-policy \
  --policy-name "${CLUSTER_NAME}-cluster-autoscaler" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup"
        ],
        "Resource": ["*"]
      },
      {
        "Effect": "Allow",
        "Action": [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup"
        ],
        "Resource": ["*"]
      }
    ]
  }'

# Create the IRSA role
aws iam create-role \
  --role-name "${CLUSTER_NAME}-cluster-autoscaler" \
  --assume-role-policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": {
        \"Federated\": \"arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}\"
      },
      \"Action\": \"sts:AssumeRoleWithWebIdentity\",
      \"Condition\": {
        \"StringEquals\": {
          \"${OIDC_PROVIDER}:sub\": \"system:serviceaccount:kube-system:cluster-autoscaler\"
        }
      }
    }]
  }"

# Attach the policy to the role
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${CLUSTER_NAME}-cluster-autoscaler"
aws iam attach-role-policy \
  --role-name "${CLUSTER_NAME}-cluster-autoscaler" \
  --policy-arn "$POLICY_ARN"
```

### Step 11 — Tag the node group ASG

The CA uses ASG tags to discover which groups it manages. The EKS Terraform module creates the node group, but the CA discovery tags may need adding:

```bash
CLUSTER_NAME=$(cd ../../eks && terraform output -raw cluster_name)

# Find the ASG for the node group
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?contains(Tags[?Key=='eks:cluster-name'].Value, '${CLUSTER_NAME}')].AutoScalingGroupName" \
  --output text)

# Add discovery tags
aws autoscaling create-or-update-tags \
  --tags \
    "ResourceId=${ASG_NAME},ResourceType=auto-scaling-group,Key=k8s.io/cluster-autoscaler/enabled,Value=true,PropagateAtLaunch=false" \
    "ResourceId=${ASG_NAME},ResourceType=auto-scaling-group,Key=k8s.io/cluster-autoscaler/${CLUSTER_NAME},Value=owned,PropagateAtLaunch=false"
```

### Step 12 — Deploy the Cluster Autoscaler

Edit `manifests/cluster-autoscaler.yaml` and replace the two placeholder values:

| Placeholder | Replace with |
|---|---|
| `ACCOUNT_ID` | Your AWS account ID (`aws sts get-caller-identity --query Account --output text`) |
| `YOUR_CLUSTER_NAME` | Your cluster name (from `terraform output -raw cluster_name`) |

Apply:

```bash
kubectl apply -f manifests/cluster-autoscaler.yaml
```

Verify the CA pod starts:

```bash
kubectl get pod -n kube-system -l app=cluster-autoscaler
kubectl logs -n kube-system deployment/cluster-autoscaler --tail=20
```

The log should show `Starting main loop` and node group discovery messages.

### Step 13 — Trigger a scale-up

Create a Deployment that requests more resources than the current nodes can provide, forcing pods into `Pending`:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: scale-trigger
spec:
  replicas: 20
  selector:
    matchLabels:
      app: scale-trigger
  template:
    metadata:
      labels:
        app: scale-trigger
    spec:
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: "500m"
              memory: "256Mi"
EOF
```

Watch pods go Pending:

```bash
kubectl get pods -l app=scale-trigger -w
```

Watch the CA log to see it detect pending pods and call the AWS API:

```bash
kubectl logs -n kube-system deployment/cluster-autoscaler -f | grep -E "scale|node|pending"
```

Watch the node count increase (typically takes 2–3 minutes for a new EC2 instance to join):

```bash
kubectl get nodes -w
```

### Step 14 — Observe scale-down

Delete the scale trigger:

```bash
kubectl delete deployment scale-trigger
```

The CA checks underutilized nodes every 10 seconds but only initiates drain after 10 minutes of sustained underutilization (configurable via `--scale-down-delay-after-add` and `--scale-down-unneeded-time`). You can watch for the `ScaleDown` log entries:

```bash
kubectl logs -n kube-system deployment/cluster-autoscaler -f | grep -i "scale.down"
```

When a node is selected for removal, the CA cordons it, drains its pods, then decrements the ASG desired count:

```bash
kubectl get nodes -w
```

---

## Step 15 — Clean up

```bash
# Exercise workloads
kubectl delete -f manifests/target-deployment.yaml
kubectl delete -f manifests/hpa.yaml
kubectl delete -f manifests/vpa.yaml
kubectl delete -f manifests/cluster-autoscaler.yaml
kubectl delete pod load-generator --ignore-not-found
kubectl delete deployment scale-trigger --ignore-not-found

# VPA components (if installed)
cd /tmp/autoscaler/vertical-pod-autoscaler && ./hack/vpa-down.sh

# IAM resources (replace CLUSTER_NAME and ACCOUNT_ID)
CLUSTER_NAME=$(cd ../../eks && terraform output -raw cluster_name)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${CLUSTER_NAME}-cluster-autoscaler"
aws iam detach-role-policy \
  --role-name "${CLUSTER_NAME}-cluster-autoscaler" \
  --policy-arn "$POLICY_ARN"
aws iam delete-role --role-name "${CLUSTER_NAME}-cluster-autoscaler"
aws iam delete-policy --policy-arn "$POLICY_ARN"
```

---

## Knowledge Check

1. An HPA has `minReplicas: 2`, `maxReplicas: 20`, and a CPU target of 60%. Current state: 5 replicas at 90% CPU. How many replicas will the HPA converge to?
2. The HPA shows `<unknown>` in the `TARGETS` column. What is the most likely cause?
3. What is the difference between VPA `Initial` and `Auto` modes?
4. Why should you avoid running HPA and VPA in `Auto` mode targeting the same CPU metric?
5. The Cluster Autoscaler is running but a Pending pod never triggers a scale-up. Name three possible causes.
6. A node has been underutilized for 12 minutes but the CA has not removed it. What is one reason it might be protected from scale-down?
7. You have a singleton StatefulSet (one replica, cannot scale horizontally). Which autoscaler is most appropriate, and which mode would you choose for production?
8. The HPA `scaleDown.stabilizationWindowSeconds` is set to `0`. What is the risk?

<details>
<summary>Answers</summary>

1. `ceil(5 × (90 / 60)) = ceil(7.5) = 8` replicas. The HPA will increase from 5 to 8.

2. The Metrics Server has not yet collected a CPU sample for that pod. It typically takes 60 seconds after the pod starts. Also check that the Metrics Server deployment is running: `kubectl get deployment metrics-server -n kube-system`.

3. `Initial` applies VPA recommendations only when a new pod is created (at admission time) — running pods are never evicted. `Auto` additionally evicts pods whose current requests are outside the recommended range and recreates them with updated requests, meaning running pods can be disrupted.

4. VPA `Auto` changes a pod's `requests`, which changes the pod's CPU utilization percentage (the denominator in the HPA formula). This re-triggers the HPA, which changes replica count, which changes the average CPU, which may re-trigger VPA — a feedback loop. Use HPA on one metric and VPA on another, or keep VPA in `Off`/`Initial` mode.

5. Three possible causes: (a) No node group can satisfy the pod's constraints — the pod has a `nodeSelector`, affinity rule, or taint toleration that no node group in the CA's discovery list can match. (b) The pod's resource request exceeds the maximum instance type in the node group (e.g. requesting 128 GiB memory on a group using t3.medium). (c) The ASG discovery tags are missing or the CA's IRSA role lacks `autoscaling:DescribeAutoScalingGroups` permission — check the CA logs.

6. A pod with no controller (bare pod), a pod with a `PodDisruptionBudget` that would be violated, or a pod with the annotation `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` will block the CA from draining the node.

7. Use **VPA** in `Auto` mode for a production singleton that cannot scale horizontally. VPA will periodically evict and restart the pod with optimized requests. Ensure the StatefulSet has a `PodDisruptionBudget` with `minAvailable: 1` only if downtime is unacceptable — but note that VPA `Auto` mode does require brief pod restarts.

8. With `stabilizationWindowSeconds: 0` on `scaleDown`, the HPA can begin reducing replicas immediately when metrics drop. After a short traffic spike, the load generator stops and CPU instantly falls, causing the HPA to scale down before the application has fully drained in-flight requests. The result is dropped connections. A stabilization window of 60–300 seconds prevents this.

</details>
