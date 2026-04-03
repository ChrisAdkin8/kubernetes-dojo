# Exercise 13 — EKS Control Plane and IAM

## Learning Objectives

By the end of this exercise you will be able to:

- Describe the IAM roles required by the EKS control plane and explain why each exists
- Inspect the EKS cluster's endpoint access configuration and explain the security trade-offs
- List the control-plane log types and query them in CloudWatch
- Explain how access entries and the `aws-auth` ConfigMap control cluster access
- Use the AWS CLI to inspect and validate the cluster configuration

---

## Background

### Control plane IAM role

EKS needs an IAM role to act on your behalf. Two policies are attached:

| Policy | Why it is needed |
|---|---|
| `AmazonEKSClusterPolicy` | Allows EKS to create and manage ENIs, security groups, and load balancers in your VPC. Also grants read access to EC2 to discover nodes. |
| `AmazonEKSVPCResourceController` | Required for the VPC CNI in "Security Group for Pods" mode. Allows EKS to manage pod-level security group assignments. |

The control plane assumes this role using a service principal trust policy (`eks.amazonaws.com`).

### API endpoint access modes

| Mode | `endpoint_public_access` | `endpoint_private_access` | Who can reach the API |
|---|---|---|---|
| Public only | `true` | `false` | Anyone on the internet (filtered by CIDRs) |
| Public + Private | `true` | `true` | Internet (CIDRs) AND resources inside the VPC |
| Private only | `false` | `true` | Only resources inside the VPC |

The Terraform in this repo uses **Public + Private** with `endpoint_private_access = true` always set. Nodes resolve `kubernetes` DNS to the private endpoint, so their traffic never leaves the VPC. External `kubectl` access uses the public endpoint.

### Control plane log types

| Log type | What it contains |
|---|---|
| `api` | Every request to the Kubernetes API server |
| `audit` | Who did what (user, verb, resource) — the security log |
| `authenticator` | IAM authentication attempts; useful for debugging RBAC |
| `controllerManager` | Reconciliation loops (deployments, replicasets, etc.) |
| `scheduler` | Pod placement decisions |

Logs are sent to CloudWatch in the log group `/aws/eks/<cluster-name>/cluster`.

### Authentication: access entries vs aws-auth

EKS supports two (compatible) mechanisms for mapping IAM principals to Kubernetes RBAC:

| Mechanism | Where it lives | How to manage |
|---|---|---|
| `aws-auth` ConfigMap | `kube-system` namespace | `kubectl edit` — legacy approach |
| **Access entries** | EKS API | `aws eks` CLI or Terraform — current approach |

The cluster uses `authentication_mode = "API_AND_CONFIG_MAP"` so both work. The Terraform grants the cluster creator `cluster-admin` via `bootstrap_cluster_creator_admin_permissions = true`.

---

## Prerequisites

```bash
export CLUSTER_NAME=my-eks-cluster
export AWS_REGION=eu-west-2

aws sts get-caller-identity
```

---

## Step 1 — Inspect the cluster

```bash
# Describe the cluster
aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --query "cluster.{Name:name,Version:version,Status:status,Endpoint:endpoint,Auth:accessConfig.authenticationMode}" \
  --output table
```

Note the `Status` — it should be `ACTIVE`. A cluster in `CREATING` or `UPDATING` state cannot accept API requests.

---

## Step 2 — Inspect the control plane IAM role

```bash
# Get the role ARN from the cluster
ROLE_ARN=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --query "cluster.roleArn" \
  --output text)

ROLE_NAME=$(basename "$ROLE_ARN")
echo "Control plane role: $ROLE_NAME"

# List the attached managed policies
aws iam list-attached-role-policies \
  --role-name "$ROLE_NAME" \
  --query "AttachedPolicies[*].{PolicyName:PolicyName,PolicyArn:PolicyArn}" \
  --output table

# Show the trust policy (who can assume this role)
aws iam get-role \
  --role-name "$ROLE_NAME" \
  --query "Role.AssumeRolePolicyDocument" \
  --output json
```

The trust policy `Principal.Service` should be `eks.amazonaws.com`. If you see an unexpected principal here, it means something other than EKS can assume the control plane role — a security concern.

---

## Step 3 — Inspect endpoint access configuration

```bash
aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --query "cluster.resourcesVpcConfig.{PublicAccess:endpointPublicAccess,PrivateAccess:endpointPrivateAccess,PublicCIDRs:publicAccessCidrs}" \
  --output table
```

If `PublicCIDRs` is `["0.0.0.0/0"]`, the API server is reachable from anywhere on the internet. For production clusters, restrict this to your office/VPN CIDR.

```bash
# Confirm kubectl is reaching the cluster successfully
kubectl cluster-info
```

---

## Step 4 — Inspect CloudWatch logging

```bash
# Confirm which log types are enabled
aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --query "cluster.logging.clusterLogging[?enabled==\`true\`].types" \
  --output json

# View the log group
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/eks/${CLUSTER_NAME}" \
  --query "logGroups[*].{LogGroup:logGroupName,RetentionDays:retentionInDays,StoredBytes:storedBytes}" \
  --output table
```

---

## Step 5 — Query a recent audit log

```bash
# Get the most recent audit log stream
LOG_STREAM=$(aws logs describe-log-streams \
  --log-group-name "/aws/eks/${CLUSTER_NAME}/cluster" \
  --log-stream-name-prefix "kube-apiserver-audit" \
  --order-by LastEventTime \
  --descending \
  --query "logStreams[0].logStreamName" \
  --output text)

echo "Log stream: $LOG_STREAM"

# Fetch the last 10 log events (each is a JSON audit record)
aws logs get-log-events \
  --log-group-name "/aws/eks/${CLUSTER_NAME}/cluster" \
  --log-stream-name "$LOG_STREAM" \
  --limit 5 \
  --query "events[*].message" \
  --output text | python3 -m json.tool 2>/dev/null | head -60
```

Each audit record shows `user.username`, `verb`, `objectRef.resource`, and `responseStatus.code` — the who, what, and outcome of every API call.

---

## Step 6 — Inspect access entries

```bash
# List all IAM principals that have been granted cluster access
aws eks list-access-entries \
  --cluster-name "$CLUSTER_NAME" \
  --query "accessEntries" \
  --output table

# Describe the access policies for one entry (replace with your principal ARN)
PRINCIPAL_ARN=$(aws eks list-access-entries \
  --cluster-name "$CLUSTER_NAME" \
  --query "accessEntries[0]" \
  --output text)

aws eks list-associated-access-policies \
  --cluster-name "$CLUSTER_NAME" \
  --principal-arn "$PRINCIPAL_ARN" \
  --query "associatedAccessPolicies[*].{Policy:policyArn,Scope:accessScope.type}" \
  --output table
```

---

## Step 7 — Inspect the aws-auth ConfigMap

```bash
# The legacy way to inspect cluster auth mappings
kubectl get configmap aws-auth -n kube-system -o yaml
```

Any IAM roles listed under `mapRoles` are granted Kubernetes RBAC group membership. Entries here are in addition to access entries from Step 6.

---

## Step 8 — Inspect managed add-ons

```bash
aws eks list-addons \
  --cluster-name "$CLUSTER_NAME" \
  --output table

aws eks describe-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name vpc-cni \
  --query "addon.{Name:addonName,Version:addonVersion,Status:status,Health:health.issues}" \
  --output json
```

All add-ons should be in `ACTIVE` status. A `DEGRADED` add-on means the control plane cannot manage its pods.

---

## Clean up

No resources were created. All steps were read-only.

---

## Knowledge Check

Answer without looking at the Terraform or AWS console:

1. What AWS managed policy allows EKS to create load balancers and ENIs in your VPC?
2. The `AmazonEKSVPCResourceController` policy is attached to the control plane role. What feature does it enable?
3. Your cluster has `endpoint_public_access = true` and `public_access_cidrs = ["0.0.0.0/0"]`. A developer asks if this is safe. What do you tell them and what would you change?
4. Nodes are in private subnets. When a node calls the Kubernetes API, which endpoint does it use — public or private?
5. You need to find out who deleted a Deployment at 14:32 UTC. Which CloudWatch log type do you query?
6. What is the difference between an access entry and an `aws-auth` ConfigMap entry?
7. `bootstrap_cluster_creator_admin_permissions = true` is set. What does this do and when would you disable it?

<details>
<summary>Answers</summary>

1. `AmazonEKSClusterPolicy`.
2. It enables "Security Groups for Pods" — the VPC CNI can assign pod-level security groups using branch ENIs, providing network-layer isolation per pod rather than per node.
3. The API server is reachable from any IP on the internet. It is protected by IAM authentication, but a more defence-in-depth approach restricts `public_access_cidrs` to your office/VPN CIDR range to reduce the exposure of the endpoint.
4. The private endpoint. EKS automatically creates a Route 53 private hosted zone that resolves `kubernetes.default.svc.cluster.local` and the API server DNS to the private endpoint IP inside your VPC.
5. The `audit` log type. Each record includes `requestReceivedTimestamp`, `user.username`, `verb=delete`, and `objectRef.resource=deployments`.
6. Access entries are managed via the EKS API and are the preferred, Terraform-compatible approach. The `aws-auth` ConfigMap is the legacy mechanism stored as a Kubernetes object in `kube-system`. Both are evaluated when `authentication_mode = "API_AND_CONFIG_MAP"`.
7. It automatically creates an access entry that grants the IAM principal used to create the cluster `cluster-admin` permissions. Disable it in automated pipelines where the Terraform runner should not retain permanent admin access after cluster creation.

</details>
