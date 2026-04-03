# Exercise 03 — Services

## Learning Objectives

By the end of this exercise you will be able to:

- Explain how Services use label selectors to route traffic to Pods
- Create ClusterIP, NodePort, and LoadBalancer Services
- Use DNS to discover Services from inside the cluster
- Port-forward to a Service or Pod for local debugging

---

## Background

A **Service** gives a stable IP address and DNS name to a dynamic set of Pods. Without a Service, Pod IPs change every time a Pod is replaced.

The Service uses a **label selector** to find its backing Pods. Traffic is load-balanced across all matching Pods that pass their readiness probe.

### Service types

| Type | Reachable from | Use case |
|---|---|---|
| `ClusterIP` (default) | Inside the cluster only | Internal microservice communication |
| `NodePort` | Any node's IP + port | Quick testing; not recommended for production |
| `LoadBalancer` | Public internet (via cloud LB) | Exposing a service externally |
| `ExternalName` | Inside the cluster | Alias an external DNS name |

---

## Prerequisites

Deploy the Deployment from exercise 02 first, or apply it directly:

```bash
kubectl apply -f ../02-deployments/manifests/deployment.yaml
```

---

## Step 1 — Create a ClusterIP Service

```bash
kubectl apply -f manifests/clusterip-service.yaml
kubectl get service web-app-clusterip
```

Test it from inside the cluster using a temporary Pod:

```bash
kubectl run test-pod --image=busybox:1.36 --restart=Never -it --rm -- \
  wget -qO- http://web-app-clusterip
```

DNS resolution works because kube-dns (CoreDNS) automatically creates a record `<service-name>.<namespace>.svc.cluster.local`:

```bash
kubectl run test-pod --image=busybox:1.36 --restart=Never -it --rm -- \
  nslookup web-app-clusterip.default.svc.cluster.local
```

---

## Step 2 — Port-forward to debug locally

`kubectl port-forward` tunnels traffic from your laptop to a Pod or Service without exposing it externally:

```bash
# Forward localhost:8080 to the Service port 80
kubectl port-forward service/web-app-clusterip 8080:80
```

In another terminal:

```bash
curl http://localhost:8080
```

Stop with `ctrl+c`.

---

## Step 3 — Create a NodePort Service

```bash
kubectl apply -f manifests/nodeport-service.yaml
kubectl get service web-app-nodeport
```

Get the node's external IP (requires nodes with public IPs):

```bash
kubectl get nodes -o wide
```

Access it via `http://<NODE_EXTERNAL_IP>:30080`.

---

## Step 4 — Create a LoadBalancer Service

> **AWS note:** This provisions a Classic Load Balancer by default. The manifest uses an annotation to request an internal NLB instead of a public-facing one.

```bash
kubectl apply -f manifests/loadbalancer-service.yaml
```

Watch until the `EXTERNAL-IP` is assigned (can take 1–2 minutes):

```bash
kubectl get service web-app-lb -w
```

Once the IP/hostname appears, test it:

```bash
curl http://<EXTERNAL-IP>
```

---

## Step 5 — Understand Endpoints

A Service maintains an **Endpoints** object listing the IPs of matching Pods:

```bash
kubectl get endpoints web-app-clusterip
kubectl describe endpoints web-app-clusterip
```

Scale the Deployment down and watch the Endpoints shrink:

```bash
kubectl scale deployment web-app --replicas=1
kubectl get endpoints web-app-clusterip
```

---

## Step 6 — Clean up

```bash
kubectl delete -f manifests/
kubectl delete -f ../02-deployments/manifests/
```

---

## Knowledge Check

1. A Service exists but its `Endpoints` list is empty. What are the two most likely causes?
2. What DNS name would a Pod use to reach a Service called `auth-service` in the `platform` namespace?
3. You have a ClusterIP Service. How do you reach it from your laptop without creating a LoadBalancer?
4. What happens to in-flight connections when a Pod is deleted while it is listed in a Service's Endpoints?
5. Explain why `NodePort` is generally not used in production.

<details>
<summary>Answers</summary>

1. (a) The label selector on the Service does not match any Pod labels. (b) All matching Pods are failing their readiness probe.
2. `auth-service.platform.svc.cluster.local` (short form `auth-service.platform` also works within the cluster).
3. `kubectl port-forward service/<name> <local-port>:<service-port>`.
4. Kubernetes sends a `SIGTERM` to the container and removes the Pod from Endpoints simultaneously. There is a small window (~1s) where in-flight requests can be dropped. `preStop` hooks and `terminationGracePeriodSeconds` are used to mitigate this.
5. It exposes a port on every node, making firewall rules complex, and the port range (30000–32767) is non-standard. It also bypasses proper load balancing at the cloud layer.

</details>
