# Exercise 04 — ConfigMaps and Secrets

## Learning Objectives

By the end of this exercise you will be able to:

- Create ConfigMaps and Secrets from manifests and imperatively
- Inject configuration as environment variables and as mounted files
- Explain the difference between `data` and `stringData` in Secrets
- Describe the security limitations of Kubernetes Secrets and list better alternatives

---

## Background

**ConfigMap** stores non-sensitive configuration (feature flags, log levels, config files).

**Secret** stores sensitive data (passwords, tokens, TLS certs). Values are base64-encoded at rest but are **not encrypted by default**. To encrypt them, enable [Envelope Encryption](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/) with a KMS provider (AWS KMS on EKS).

For production workloads, prefer [AWS Secrets Manager](https://docs.aws.amazon.com/secretsmanager/) with the [External Secrets Operator](https://external-secrets.io/) or the [AWS Secrets and Configuration Provider (ASCP)](https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_csi_driver.html) rather than Kubernetes Secrets.

---

## Step 1 — Create the ConfigMap and Secret

```bash
kubectl apply -f manifests/configmap.yaml
kubectl apply -f manifests/secret.yaml
```

Inspect the ConfigMap:

```bash
kubectl get configmap app-config -o yaml
```

Inspect the Secret (values are base64-encoded):

```bash
kubectl get secret app-secret -o yaml
```

Decode a secret value:

```bash
kubectl get secret app-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
```

---

## Step 2 — Create a ConfigMap imperatively

```bash
# From literal values
kubectl create configmap env-config \
  --from-literal=ENVIRONMENT=staging \
  --from-literal=DEBUG=false

# From a file (key = filename, value = file contents)
kubectl create configmap nginx-conf \
  --from-file=nginx.conf=/etc/nginx/nginx.conf

# Verify
kubectl describe configmap env-config
```

---

## Step 3 — Create a Secret imperatively

```bash
kubectl create secret generic db-creds \
  --from-literal=username=admin \
  --from-literal=password='S3cr3t!'

kubectl get secret db-creds -o yaml
```

---

## Step 4 — Consume the ConfigMap and Secret in a Pod

```bash
kubectl apply -f manifests/pod-with-config.yaml
```

Wait for it to start:

```bash
kubectl wait pod app-with-config --for=condition=Ready --timeout=30s
```

View the logs to confirm the environment variables are injected:

```bash
kubectl logs app-with-config
```

Exec in and inspect the mounted config file:

```bash
kubectl exec app-with-config -- ls /etc/config
kubectl exec app-with-config -- cat /etc/config/app.properties
```

---

## Step 5 — Update a ConfigMap and observe the behaviour

Edit the ConfigMap to change `LOG_LEVEL`:

```bash
kubectl edit configmap app-config
# Change LOG_LEVEL from "info" to "debug"
```

Check the mounted file inside the Pod (updates propagate within ~60 seconds):

```bash
kubectl exec app-with-config -- cat /etc/config/app.properties
```

> **Important:** Environment variables (`env:` / `envFrom:`) are **not** updated when a ConfigMap changes. The Pod must be restarted to pick up new env values. Mounted files are updated automatically.

---

## Step 6 — Clean up

```bash
kubectl delete -f manifests/
kubectl delete configmap env-config nginx-conf
kubectl delete secret db-creds
```

---

## Knowledge Check

1. What is the difference between `data` and `stringData` in a Secret manifest?
2. A Pod reads a ConfigMap value as an environment variable. You update the ConfigMap. Does the Pod see the new value? What must you do?
3. Why are Kubernetes Secrets not actually secret by default?
4. You want a Pod to get a fresh AWS Secrets Manager value on every start without rebuilding the image. What approach would you use on EKS?
5. A mounted ConfigMap file has stale content. How long does the kubelet take to propagate updates?

<details>
<summary>Answers</summary>

1. `data` requires pre-encoded base64 values. `stringData` accepts plain text and Kubernetes encodes it. `stringData` is write-only — it does not appear in `kubectl get secret -o yaml`.
2. No. Environment variables are set at container start and do not update dynamically. You must restart (delete) the Pod or trigger a rollout (`kubectl rollout restart deployment/<name>`).
3. By default, Secrets are only base64-encoded (not encrypted) in etcd. Any user with `get secret` RBAC permission or direct etcd access can read them.
4. Use the [AWS Secrets and Configuration Provider (ASCP)](https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_csi_driver.html) with the Secrets Store CSI Driver, which mounts secrets as files and rotates them automatically.
5. Up to the `--sync-frequency` kubelet flag (default 1 minute) plus the ConfigMap cache TTL (~30 seconds). Expect 60–90 seconds in practice.

</details>
