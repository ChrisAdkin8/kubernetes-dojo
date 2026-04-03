# Exercise 06 — RBAC

## Learning Objectives

By the end of this exercise you will be able to:

- Explain the four RBAC objects and how they relate to each other
- Create a ServiceAccount, Role, and RoleBinding
- Create a ClusterRole and ClusterRoleBinding
- Test RBAC rules using `kubectl auth can-i`
- Explain how IRSA (IAM Roles for Service Accounts) works on EKS

---

## Background

Kubernetes RBAC controls **what** a subject can do **on which resources**.

### The four RBAC objects

| Object | Scope | Purpose |
|---|---|---|
| `Role` | Namespace | Defines a set of permissions within one namespace |
| `ClusterRole` | Cluster-wide | Defines permissions across all namespaces or on cluster-scoped resources (nodes, PVs) |
| `RoleBinding` | Namespace | Grants a Role or ClusterRole to a subject within one namespace |
| `ClusterRoleBinding` | Cluster-wide | Grants a ClusterRole to a subject across the entire cluster |

### Subjects

A binding can grant permissions to:
- `User` — a human user authenticated by the cluster's auth provider
- `Group` — a group of users
- `ServiceAccount` — an in-cluster identity used by Pods

### IRSA on EKS

EKS extends RBAC with **IAM Roles for Service Accounts (IRSA)**. By annotating a ServiceAccount with an IAM role ARN and configuring a trust policy on the IAM role, Pods using that ServiceAccount can assume the IAM role and call AWS APIs — without static credentials.

---

## Step 1 — Create the ServiceAccount, Role, and RoleBinding

```bash
kubectl apply -f manifests/service-account.yaml
kubectl apply -f manifests/role-and-binding.yaml
```

Verify they were created:

```bash
kubectl get serviceaccount pod-reader-sa
kubectl get role pod-reader
kubectl get rolebinding pod-reader-binding
```

---

## Step 2 — Test the permissions

Check what the ServiceAccount can do using `kubectl auth can-i`:

```bash
# Can it list pods? (should be yes)
kubectl auth can-i list pods \
  --as=system:serviceaccount:default:pod-reader-sa

# Can it delete pods? (should be no)
kubectl auth can-i delete pods \
  --as=system:serviceaccount:default:pod-reader-sa

# Can it list deployments? (should be no)
kubectl auth can-i list deployments \
  --as=system:serviceaccount:default:pod-reader-sa

# Can it list pods in the kube-system namespace? (should be no — Role is namespaced)
kubectl auth can-i list pods \
  --as=system:serviceaccount:default:pod-reader-sa \
  -n kube-system
```

---

## Step 3 — Run a Pod as the ServiceAccount

Create a Pod that uses the ServiceAccount:

```bash
kubectl run rbac-test \
  --image=bitnami/kubectl:latest \
  --serviceaccount=pod-reader-sa \
  --restart=Never \
  -it --rm \
  -- kubectl get pods
```

The Pod should be able to list Pods in its own namespace.

Try listing Pods in another namespace (should fail):

```bash
kubectl run rbac-test \
  --image=bitnami/kubectl:latest \
  --serviceaccount=pod-reader-sa \
  --restart=Never \
  -it --rm \
  -- kubectl get pods -n kube-system
```

---

## Step 4 — Create a ClusterRole and ClusterRoleBinding

```bash
kubectl apply -f manifests/clusterrole-and-binding.yaml
```

Now the ServiceAccount has read access cluster-wide:

```bash
kubectl auth can-i list pods \
  --as=system:serviceaccount:default:pod-reader-sa \
  -n kube-system
# Should now return yes
```

---

## Step 5 — Inspect existing RBAC rules

View the built-in ClusterRoles:

```bash
kubectl get clusterrole
kubectl describe clusterrole cluster-admin
kubectl describe clusterrole view
kubectl describe clusterrole edit
```

Find all bindings for a specific ServiceAccount:

```bash
kubectl get rolebindings,clusterrolebindings \
  -o jsonpath='{range .items[?(@.subjects[*].name=="pod-reader-sa")]}{.kind}/{.metadata.name}{"\n"}{end}' \
  --all-namespaces
```

---

## Step 6 — Clean up

```bash
kubectl delete -f manifests/
```

---

## Knowledge Check

1. What is the difference between a `Role` and a `ClusterRole`?
2. Can you use a `RoleBinding` to grant a `ClusterRole`? What would the effective scope be?
3. A Pod keeps getting `403 Forbidden` errors when it calls the Kubernetes API. Walk through your debugging steps.
4. What does `kubectl auth can-i create deployments --as=jane` tell you?
5. On EKS, a Pod needs to read from S3. How do you grant it access without storing AWS credentials in a Secret?

<details>
<summary>Answers</summary>

1. A `Role` is namespace-scoped and can only grant permissions on resources within one namespace. A `ClusterRole` is cluster-scoped and can grant permissions on resources in any namespace, or on cluster-scoped resources (nodes, PVs, namespaces).
2. Yes. A `RoleBinding` that references a `ClusterRole` grants only the permissions in the named namespace (not cluster-wide). This is useful for reusing a common ClusterRole in multiple namespaces without granting cluster-wide access.
3. (a) `kubectl auth can-i <verb> <resource> --as=system:serviceaccount:<ns>:<sa-name>` to check what the SA is allowed to do. (b) `kubectl describe rolebinding,clusterrolebinding --all-namespaces` to see what bindings exist. (c) Check the Pod's `spec.serviceAccountName` to confirm which SA it is using.
4. It impersonates the user `jane` and checks whether she has permission to create Deployments in the current namespace. Useful for auditing permissions.
5. Use IRSA: (a) Create an IAM role with an S3 read policy and a trust policy allowing the OIDC provider. (b) Annotate the ServiceAccount with `eks.amazonaws.com/role-arn: <role-arn>`. (c) The AWS SDK inside the Pod automatically assumes the role via the projected token.

</details>
