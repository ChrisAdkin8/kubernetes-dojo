# Kubernetes Dojo

A hands-on learning environment for developing fluency with Kubernetes. The goal is to build **muscle memory** — so that common operations become second nature through deliberate, repeated practice.

## Structure

```
kubernetes-dojo/
├── eks/                          — Terraform to provision an EKS cluster on AWS
│   ├── modules/
│   │   ├── vpc/                  — VPC, subnets, NAT gateways
│   │   ├── eks_cluster/          — EKS control plane, IAM, OIDC, add-ons
│   │   └── node_group/           — Managed node group with launch template
│   └── README.md
│
└── exercises/
    ├── 01-pods-and-containers/   — Pod lifecycle, exec, logs, init containers, sidecars
    ├── 02-deployments/           — Rolling updates, rollback, scaling
    ├── 03-services/              — ClusterIP, NodePort, LoadBalancer, DNS, port-forward
    ├── 04-configmaps-and-secrets/— Injecting config and secrets, update behaviour
    ├── 05-persistent-storage/    — StorageClass, PVC, EBS CSI driver, data persistence
    ├── 06-rbac/                  — ServiceAccounts, Roles, Bindings, IRSA
    ├── 07-scheduling/            — nodeSelector, affinity, taints/tolerations, spread
    ├── 08-resource-management/   — Requests/limits, QoS, ResourceQuota, HPA
    ├── 09-network-policies/      — Default deny, allow-listing, DNS egress
    ├── 10-troubleshooting/       — CrashLoopBackOff, OOMKilled, ImagePullBackOff, events
    │
    │   AWS infrastructure exercises (use aws CLI + kubectl to inspect live resources)
    │
    ├── 11-vpc-networking/        — VPC, public/private subnets, IGW, subnet tags for ELB
    ├── 12-nat-and-routing/       — NAT Gateways, EIPs, route tables, pod egress path
    ├── 13-eks-control-plane/     — Cluster IAM role, endpoint access, CloudWatch logs, auth
    ├── 14-oidc-and-irsa/         — OIDC provider, IRSA trust policies, ServiceAccount annotation
    └── 15-managed-node-groups/   — Node IAM role, ASG, ON_DEMAND vs SPOT, pod IP capacity
```

Each exercise directory contains:
- `README.md` — background, step-by-step instructions, and a knowledge check
- `manifests/` — YAML files to apply against the cluster

---

## Getting Started

### Step 1 — Provision the cluster

Follow the instructions in [`eks/README.md`](eks/README.md) to deploy the EKS cluster with Terraform.

Prerequisites:
- [Terraform >= 1.9.0](https://developer.hashicorp.com/terraform/install)
- [AWS CLI >= 2.0](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) — configured with credentials
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

Quick start:

```bash
cd eks
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — set your region at minimum
terraform init
terraform apply
$(terraform output -raw kubeconfig_command)
```

Verify the cluster is healthy:

```bash
kubectl get nodes
kubectl get pods -n kube-system
```

### Step 2 — Work through the exercises

Each exercise is self-contained. They are roughly ordered by complexity — start at 01 and work forward.

```bash
cd exercises/01-pods-and-containers
# read the README, then:
kubectl apply -f manifests/nginx-pod.yaml
```

### Step 3 — Clean up after each exercise

Each exercise README includes a "Clean up" step. Run it before moving to the next exercise to keep the cluster tidy.

---

## Exercise Overview

### Kubernetes exercises

| # | Topic | Key concepts |
|---|---|---|
| 01 | Pods and containers | `kubectl exec`, `kubectl logs`, init containers, sidecars, Pod phases |
| 02 | Deployments | Rolling update, rollback, `kubectl rollout`, ReplicaSet |
| 03 | Services | ClusterIP, NodePort, LoadBalancer, DNS, port-forward, Endpoints |
| 04 | ConfigMaps and Secrets | `envFrom`, `valueFrom`, volume mounts, update propagation |
| 05 | Persistent storage | StorageClass, PVC, EBS gp3, `WaitForFirstConsumer`, data persistence |
| 06 | RBAC | ServiceAccount, Role, ClusterRole, RoleBinding, `auth can-i`, IRSA |
| 07 | Scheduling | `nodeSelector`, affinity/anti-affinity, taints, tolerations, topology spread |
| 08 | Resource management | Requests vs limits, QoS classes, ResourceQuota, LimitRange, HPA |
| 09 | Network Policies | Default deny-all, allow-listing, egress rules, DNS, CNI requirements |
| 10 | Troubleshooting | CrashLoopBackOff, OOMKilled, ImagePullBackOff, events, debug Pods |

### AWS infrastructure exercises

These exercises use the `aws` CLI and `kubectl` to inspect the live AWS resources that support the cluster. Exercises 11–14 are read-only; exercise 14 creates and deletes IAM resources, and exercise 15 scales the node group up and back down.

| # | Topic | Key concepts |
|---|---|---|
| 11 | VPC networking | Public/private subnets, IGW, DNS settings, ELB subnet tags |
| 12 | NAT Gateways and routing | NAT GW per AZ, EIPs, public/private route tables, pod egress path |
| 13 | EKS control plane and IAM | Cluster IAM role, endpoint access, CloudWatch logs, access entries |
| 14 | OIDC and IRSA | OIDC provider, trust policy, ServiceAccount annotation, pod identity |
| 15 | Managed node groups | Node IAM role, ASG, ON_DEMAND vs SPOT, pod IP capacity, scale operations |

---

## Useful kubectl Aliases

Add these to your shell profile to speed up your workflow:

```bash
alias k='kubectl'
alias kgp='kubectl get pods'
alias kgpw='kubectl get pods -w'
alias kgpa='kubectl get pods --all-namespaces'
alias kgs='kubectl get services'
alias kgn='kubectl get nodes'
alias kd='kubectl describe'
alias kl='kubectl logs'
alias klf='kubectl logs -f'
alias ke='kubectl exec -it'
alias ka='kubectl apply -f'
alias krm='kubectl delete'
alias kctx='kubectl config current-context'
alias kns='kubectl config set-context --current --namespace'

# Show current namespace in prompt
export PS1='[\u@\h \W $(kubectl config view --minify --output "jsonpath={.contexts[0].context.namespace}" 2>/dev/null)]\$ '
```

---

## Quick Reference

### Imperative commands (fast in practice)

```bash
# Create a Pod and immediately exec into it
kubectl run tmp --image=busybox:1.36 --restart=Never -it --rm -- /bin/sh

# Create a Deployment
kubectl create deployment web --image=nginx:1.27-alpine --replicas=3

# Expose a Deployment as a ClusterIP Service
kubectl expose deployment web --port=80

# Scale a Deployment
kubectl scale deployment web --replicas=5

# Update an image
kubectl set image deployment/web web=nginx:1.26-alpine

# Create a ConfigMap from a literal
kubectl create configmap my-config --from-literal=KEY=value

# Create a Secret from literals
kubectl create secret generic my-secret --from-literal=password=secret123

# Copy a file into a running container
kubectl cp ./local-file.txt my-pod:/tmp/

# Get all resources in a namespace
kubectl get all -n my-namespace

# Watch events in real time
kubectl get events --sort-by='.lastTimestamp' -w

# Check what a ServiceAccount can do
kubectl auth can-i list pods --as=system:serviceaccount:default:my-sa
```

### Generating manifests from imperative commands

Use `--dry-run=client -o yaml` to generate a manifest without creating the resource:

```bash
kubectl run nginx --image=nginx:1.27-alpine --dry-run=client -o yaml > pod.yaml
kubectl create deployment web --image=nginx:1.27-alpine --dry-run=client -o yaml > deployment.yaml
kubectl expose deployment web --port=80 --dry-run=client -o yaml > service.yaml
```

---

## Estimated Cost

The default cluster configuration (2× t3.medium nodes, eu-west-2) costs approximately:

| Resource | Monthly cost (approx.) |
|---|---|
| EKS control plane | $73 |
| 2× t3.medium (on-demand) | $60 |
| NAT Gateways (2×) | $65 |
| EBS storage | ~$5 |
| **Total** | **~$203/month** |

To reduce cost:
- Use `node_capacity_type = "SPOT"` (up to 70% cheaper for nodes)
- Reduce to one NAT gateway by setting `availability_zones = ["eu-west-2a"]` and one subnet pair
- Destroy the cluster when not in use: `terraform destroy`

---

## Destroying the Cluster

When you are done with all exercises, tear down the cluster to stop incurring charges:

```bash
cd eks
terraform destroy
```

> **Before destroying:** delete any PersistentVolumeClaims you want to keep data from, as the StorageClass has `reclaimPolicy: Delete`.
