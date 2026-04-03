# Exercise 09 — Network Policies

## Learning Objectives

By the end of this exercise you will be able to:

- Explain how NetworkPolicies are enforced and by which component
- Apply a default deny-all policy to a namespace
- Layer allow policies for specific traffic flows
- Verify that policies are working using temporary test Pods
- Describe the EKS-specific requirements for NetworkPolicy enforcement

---

## Background

By default, all Pods in a Kubernetes cluster can communicate freely with each other. A **NetworkPolicy** selects Pods with a label selector and defines which ingress and egress traffic is allowed. Traffic not matching any policy is dropped.

### Key rules

- NetworkPolicies are **additive** — multiple policies combine with OR logic.
- A Policy applies to a Pod if the Pod matches `spec.podSelector`.
- An empty `podSelector` (`{}`) matches **all** Pods in the namespace.
- `policyTypes` must explicitly include `Ingress`, `Egress`, or both for the restrictions to apply.

### EKS requirement

The default Amazon VPC CNI does **not** enforce NetworkPolicies. You need one of:

- [Amazon VPC CNI Network Policy add-on](https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy.html) — AWS-managed, recommended for EKS
- [Calico](https://docs.tigera.io/calico/latest/getting-started/kubernetes/managed-public-cloud/eks) — open source, feature-rich
- [Cilium](https://docs.cilium.io/en/stable/installation/k8s-install-eks/) — eBPF-based, high-performance

Enable the VPC CNI Network Policy add-on:

```bash
aws eks update-addon \
  --cluster-name k8s-dojo \
  --addon-name vpc-cni \
  --configuration-values '{"enableNetworkPolicy": "true"}' \
  --region eu-west-2
```

---

## Step 1 — Deploy a test application

```bash
# Frontend
kubectl run frontend \
  --image=nginx:1.27-alpine \
  --labels=tier=frontend \
  --expose --port=80

# Backend
kubectl run backend \
  --image=nginx:1.27-alpine \
  --labels=tier=backend \
  --expose --port=8080

# Database
kubectl run database \
  --image=postgres:16-alpine \
  --labels=tier=database \
  --env=POSTGRES_PASSWORD=test \
  --expose --port=5432
```

Verify that all Pods can communicate before any NetworkPolicy is applied:

```bash
kubectl exec frontend -- wget -qO- http://backend:8080
kubectl exec backend -- nc -zv database 5432
```

---

## Step 2 — Apply default deny-all

```bash
kubectl apply -f manifests/deny-all.yaml
```

Verify that all traffic is now blocked:

```bash
kubectl exec frontend -- wget -T2 -qO- http://backend:8080 2>&1 || echo "BLOCKED"
kubectl exec backend -- nc -zv -w2 database 5432 2>&1 || echo "BLOCKED"
```

Both should be blocked.

---

## Step 3 — Layer allow policies

```bash
kubectl apply -f manifests/allow-frontend-to-backend.yaml
```

Test:

```bash
# Frontend → backend: should work
kubectl exec frontend -- wget -T2 -qO- http://backend:8080
# Database → backend: should be blocked
kubectl exec database -- wget -T2 -qO- http://backend:8080 2>&1 || echo "BLOCKED"
# Backend → database: should work
kubectl exec backend -- nc -zv -w2 database 5432
# Frontend → database: should be blocked
kubectl exec frontend -- nc -zv -w2 database 5432 2>&1 || echo "BLOCKED"
```

---

## Step 4 — Verify DNS still works

With the deny-all egress policy, DNS lookups (port 53) are also blocked. The `allow-dns-egress` policy in the manifest file re-enables them.

```bash
kubectl exec frontend -- nslookup backend.default.svc.cluster.local
```

---

## Step 5 — Clean up

```bash
kubectl delete -f manifests/
kubectl delete pod frontend backend database
kubectl delete service frontend backend database
```

---

## Knowledge Check

1. A NetworkPolicy with `podSelector: {}` and no `ingress` or `egress` rules but `policyTypes: [Ingress]` — what does it do?
2. You apply a NetworkPolicy that allows frontend→backend. Nothing changes — traffic is still blocked. What is the most likely cause?
3. How do you allow a Pod to make outbound calls to the internet while keeping deny-all egress in place?
4. Can a NetworkPolicy in namespace A affect Pods in namespace B?
5. Why does applying `deny-all` often break DNS resolution, and how do you fix it?

<details>
<summary>Answers</summary>

1. It blocks all ingress to every Pod in the namespace (because `policyTypes` includes `Ingress` but no ingress rules are defined). Egress is not affected.
2. The CNI plugin does not support NetworkPolicy enforcement. On EKS, verify that the VPC CNI Network Policy add-on is enabled, or that Calico/Cilium is installed.
3. Add an egress policy that allows traffic to `0.0.0.0/0` on the necessary ports (e.g. 443 for HTTPS). Keep the deny-all in place — the allow policy adds to it.
4. Only if the policy in namespace A uses a `namespaceSelector` to match namespace B as a source or destination. Policies do not have direct cross-namespace authority — they control traffic flowing *into* or *out of* the Pods they select.
5. DNS uses port 53. A deny-all egress policy blocks UDP/TCP port 53, so CoreDNS lookups fail. Fix by adding an egress rule allowing port 53 to the kube-dns Service or to the `kube-system` namespace (as shown in `allow-frontend-to-backend.yaml`).

</details>
