# Exercise 15 — Managed Node Groups

## Learning Objectives

By the end of this exercise you will be able to:

- Describe the IAM roles and policies required by EKS worker nodes
- Explain the difference between ON_DEMAND and SPOT capacity types
- Inspect a managed node group's scaling configuration and current state
- Manually scale a node group and observe the effect on the cluster
- Understand how nodes register with the control plane

---

## Background

### What is a managed node group?

A managed node group is a set of EC2 instances (nodes) that EKS creates and manages in an Auto Scaling Group (ASG). AWS handles:
- Launching nodes with the correct AMI (Amazon EKS-optimized Linux)
- Draining nodes before termination during updates
- Applying security patches via node group updates

You retain control of instance types, scaling limits, and capacity type.

### Node IAM role

Each worker node needs an IAM role to:
- Authenticate to the control plane (via `AmazonEKSWorkerNodePolicy`)
- Pull images from ECR (`AmazonEC2ContainerRegistryReadOnly`)
- Manage pod networking via the VPC CNI (`AmazonEKS_CNI_Policy`)

| Policy | Purpose |
|---|---|
| `AmazonEKSWorkerNodePolicy` | Lets the node call the EKS API to register with the cluster and receive cluster credentials |
| `AmazonEC2ContainerRegistryReadOnly` | Lets the container runtime pull images from Amazon ECR |
| `AmazonEKS_CNI_Policy` | Lets the VPC CNI plugin manage ENIs and assign secondary IPs to pods |

The node IAM role is distinct from the cluster IAM role from Exercise 13. The cluster role is assumed by the control plane; the node role is assumed by the EC2 instance (the worker).

### ON_DEMAND vs SPOT capacity types

| Capacity type | Cost | Interruption risk | Use case |
|---|---|---|---|
| `ON_DEMAND` | Full price | None | Stateful workloads, strict availability requirements |
| `SPOT` | Up to 90% discount | Can be reclaimed with 2-minute warning | Stateless, fault-tolerant, batch workloads |

For mixed workloads, a common pattern is two node groups: one on-demand for system/stateful pods and one spot for stateless application pods, using taints or node selectors to steer pods.

### VPC CNI and secondary IPs

Each node is assigned a primary ENI. The VPC CNI attaches additional ENIs (or assigns secondary IPs on the primary ENI) to satisfy pod IP demands. This means:
- **Pod IPs come directly from the VPC CIDR** — no overlay network
- The maximum number of pods per node is bounded by the number of IPs the instance type supports
- Plan your subnet CIDR sizes to accommodate both node IPs and pod IPs

---

## Prerequisites

```bash
export CLUSTER_NAME=my-eks-cluster
export AWS_REGION=eu-west-2
export NODE_GROUP_NAME=general
```

---

## Step 1 — Inspect the node group

```bash
aws eks describe-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODE_GROUP_NAME" \
  --query "nodegroup.{Name:nodegroupName,Status:status,CapacityType:capacityType,InstanceTypes:instanceTypes,AMI:releaseVersion,DiskSize:diskSize}" \
  --output table
```

---

## Step 2 — Inspect the scaling configuration

```bash
aws eks describe-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODE_GROUP_NAME" \
  --query "nodegroup.scalingConfig" \
  --output table
```

Note `minSize`, `maxSize`, and `desiredSize`. The ASG will not scale below `minSize` or above `maxSize` regardless of HPA or Cluster Autoscaler demands.

---

## Step 3 — Inspect the node IAM role

```bash
# Get the node role ARN
NODE_ROLE_ARN=$(aws eks describe-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODE_GROUP_NAME" \
  --query "nodegroup.nodeRole" \
  --output text)

NODE_ROLE_NAME=$(basename "$NODE_ROLE_ARN")
echo "Node role: $NODE_ROLE_NAME"

# List attached policies
aws iam list-attached-role-policies \
  --role-name "$NODE_ROLE_NAME" \
  --query "AttachedPolicies[*].{PolicyName:PolicyName}" \
  --output table

# Show the trust policy (should trust ec2.amazonaws.com)
aws iam get-role \
  --role-name "$NODE_ROLE_NAME" \
  --query "Role.AssumeRolePolicyDocument" \
  --output json
```

The trust policy `Principal.Service` should be `ec2.amazonaws.com` — the EC2 service assumes this role when an instance launches, attaching it as the instance profile.

---

## Step 4 — Inspect the underlying Auto Scaling Group

```bash
# Find the ASG name from the node group
ASG_NAME=$(aws eks describe-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODE_GROUP_NAME" \
  --query "nodegroup.resources.autoScalingGroups[0].name" \
  --output text)

echo "ASG: $ASG_NAME"

aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query "AutoScalingGroups[0].{Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,Instances:Instances[*].{InstanceId:InstanceId,AZ:AvailabilityZone,State:LifecycleState,Health:HealthStatus}}" \
  --output json
```

Each instance should show `LifecycleState: InService` and `HealthStatus: Healthy`.

---

## Step 5 — Correlate nodes between Kubernetes and AWS

```bash
# List nodes in Kubernetes
kubectl get nodes -o wide

# List EC2 instances in the node group
aws ec2 describe-instances \
  --filters \
    "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" \
    "Name=tag:eks:nodegroup-name,Values=${NODE_GROUP_NAME}" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].{InstanceId:InstanceId,PrivateIP:PrivateIpAddress,AZ:Placement.AvailabilityZone,InstanceType:InstanceType}" \
  --output table
```

The `PrivateIP` of each EC2 instance should match the `INTERNAL-IP` shown in `kubectl get nodes -o wide`. Nodes register with the API server using their private IP.

---

## Step 6 — Inspect pod IP capacity per node

```bash
# For each node, show allocated pod IPs vs the instance limit
kubectl get nodes -o json | python3 - << 'EOF'
import json, sys
data = json.load(sys.stdin)
for node in data["items"]:
    name = node["metadata"]["name"]
    allocatable = node["status"]["allocatable"]
    capacity = node["status"]["capacity"]
    print(f"{name}: pods allocatable={allocatable.get('pods','?')} capacity={capacity.get('pods','?')}")
EOF
```

Cross-reference the `pods` limit with the AWS documentation for your instance type (e.g. `t3.medium` supports up to 17 pods per node with the default VPC CNI configuration).

---

## Step 7 — Scale the node group up and observe

```bash
# Scale from 2 to 3 nodes
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODE_GROUP_NAME" \
  --scaling-config desiredSize=3

# Watch nodes join the cluster
kubectl get nodes -w
```

Wait until the new node reaches `Ready` status (typically 90–120 seconds). The sequence is:
1. ASG launches a new EC2 instance
2. Instance bootstraps with the EKS-optimized AMI
3. `kubelet` starts and registers with the control plane using the node IAM role
4. Node transitions to `Ready`

---

## Step 8 — Scale back down

```bash
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODE_GROUP_NAME" \
  --scaling-config desiredSize=2

# Watch the node drain and terminate
kubectl get nodes -w
```

EKS drains the node (cordons it, then evicts pods) before terminating the EC2 instance.

---

## Clean up

No persistent AWS resources were created. The node group was scaled back to its original size in Step 8.

---

## Knowledge Check

Answer without looking at the steps above:

1. Which IAM policy allows a worker node to pull container images from Amazon ECR?
2. A node group has `minSize=1, maxSize=5, desiredSize=2`. The Cluster Autoscaler requests a scale-out to 6 nodes. What happens?
3. You are running a batch ML training job that can tolerate interruption. Which capacity type would you choose and why?
4. A node is `NotReady`. You check EC2 and the instance is running and healthy. What is the first thing you check in the node IAM role?
5. Your subnet has a `/24` CIDR (256 IPs). You have 5 nodes each running 20 pods. Will you run out of pod IPs? Show your reasoning.
6. Why does the node IAM role trust `ec2.amazonaws.com` and not `eks.amazonaws.com`?
7. What does EKS do to a node before terminating it during a scale-in event?

<details>
<summary>Answers</summary>

1. `AmazonEC2ContainerRegistryReadOnly`.
2. The ASG will not scale past `maxSize=5`. The Cluster Autoscaler will log a `MaxNodeProvisionTime` or resource constraint event. To scale to 6 you must first update `maxSize`.
3. SPOT. Spot instances can be reclaimed by AWS with a 2-minute warning. Batch ML jobs can be checkpointed and restarted — they tolerate interruption and benefit from up to 90% cost savings.
4. Confirm that `AmazonEKSWorkerNodePolicy` is attached. Without it, `kubelet` cannot authenticate to the EKS API server, so the node cannot register. Also check that the instance profile is attached to the EC2 instance.
5. 5 nodes × 1 node IP = 5 IPs for nodes. 5 nodes × 20 pods = 100 IPs for pods. Total = 105 IPs. A `/24` has 256 addresses minus 5 AWS-reserved = 251 usable. 105 < 251, so you will not run out. You would run out if you grew to roughly 12 nodes at 20 pods each (12 + 240 = 252 > 251).
6. Worker nodes are EC2 instances, and AWS attaches the role as an instance profile. EC2 instances can only assume roles that trust `ec2.amazonaws.com`. The `eks.amazonaws.com` principal is for the managed control plane service.
7. EKS cordons the node (marks it unschedulable) and then drains it — evicting all non-daemonset pods gracefully, respecting `PodDisruptionBudgets` and termination grace periods. Only then does it terminate the EC2 instance.

</details>
