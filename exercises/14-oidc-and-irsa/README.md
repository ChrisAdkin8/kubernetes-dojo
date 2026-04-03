# Exercise 14 — OIDC Provider and IRSA

## Learning Objectives

By the end of this exercise you will be able to:

- Explain how IRSA (IAM Roles for Service Accounts) works end-to-end
- Inspect the OIDC provider attached to your cluster
- Write the IAM trust policy that scopes a role to a specific Kubernetes ServiceAccount
- Annotate a ServiceAccount and verify a pod assumes the expected IAM identity
- Debug common IRSA misconfigurations

---

## Background

### The problem IRSA solves

Without IRSA, pods that need to call AWS APIs have two bad options:
1. Hardcode long-lived credentials as Secrets — a security risk.
2. Use the node's IAM instance profile — every pod on the node gets the same permissions, violating least-privilege.

IRSA lets each pod assume its own IAM role with a short-lived token, scoped to a specific Kubernetes namespace and ServiceAccount.

### How it works

```
Pod starts
  ↓
kubelet mounts a projected ServiceAccount token into /var/run/secrets/eks.amazonaws.com/serviceaccount/token
  ↓
Pod calls sts:AssumeRoleWithWebIdentity with that token
  ↓
STS verifies the token with the cluster's OIDC provider
  ↓
STS returns temporary credentials (Access Key, Secret Key, Session Token)
  ↓
Pod uses credentials to call AWS APIs
```

The OIDC provider is the trust anchor. It allows AWS STS to validate that the token really came from your specific EKS cluster.

### IAM trust policy for IRSA

The trust policy on the IAM role scopes it to exactly one Kubernetes ServiceAccount:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/<OIDC_URL>"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "<OIDC_URL>:sub": "system:serviceaccount:<NAMESPACE>:<SERVICE_ACCOUNT_NAME>",
          "<OIDC_URL>:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

The `sub` condition is critical — it prevents any other pod (or a different ServiceAccount in the same cluster) from assuming this role.

### ServiceAccount annotation

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-sa
  namespace: default
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<ACCOUNT_ID>:role/my-irsa-role
```

The EKS Pod Identity webhook reads this annotation and mutates the pod spec to inject:
- The projected token volume
- `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE` environment variables

---

## Prerequisites

```bash
export CLUSTER_NAME=my-eks-cluster
export AWS_REGION=eu-west-2
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $AWS_ACCOUNT_ID"
```

---

## Step 1 — Inspect the OIDC provider

```bash
# Get the OIDC issuer URL from the cluster
OIDC_URL=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --query "cluster.identity.oidc.issuer" \
  --output text)
echo "OIDC issuer: $OIDC_URL"

# Strip the https:// prefix (used in IAM trust policies)
OIDC_PROVIDER=$(echo "$OIDC_URL" | sed 's|https://||')
echo "OIDC provider (no scheme): $OIDC_PROVIDER"

# Confirm the provider exists in IAM
aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[*].Arn" \
  --output table

# Inspect the provider details
OIDC_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "$OIDC_ARN" \
  --query "{URL:Url,ClientIDs:ClientIDList,Thumbprint:ThumbprintList}" \
  --output table
```

The `ClientIDs` should include `sts.amazonaws.com`. The thumbprint authenticates the OIDC provider's TLS certificate.

---

## Step 2 — Create an IRSA-enabled IAM role

This creates an IAM role scoped to a ServiceAccount named `s3-reader` in the `default` namespace with read-only S3 access.

```bash
# Build the trust policy document
cat > /tmp/irsa-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:default:s3-reader",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

# Create the role
aws iam create-role \
  --role-name "${CLUSTER_NAME}-s3-reader" \
  --assume-role-policy-document file:///tmp/irsa-trust-policy.json \
  --query "Role.Arn" \
  --output text

# Attach a permissions policy (read-only S3)
aws iam attach-role-policy \
  --role-name "${CLUSTER_NAME}-s3-reader" \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
```

---

## Step 3 — Create the annotated ServiceAccount

```bash
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-s3-reader"

kubectl create serviceaccount s3-reader --namespace default

kubectl annotate serviceaccount s3-reader \
  --namespace default \
  "eks.amazonaws.com/role-arn=${ROLE_ARN}"

# Confirm the annotation
kubectl get serviceaccount s3-reader -o jsonpath='{.metadata.annotations}' | python3 -m json.tool
```

---

## Step 4 — Verify pod identity

```bash
# Launch a pod using the annotated ServiceAccount
kubectl run irsa-test \
  --image=amazon/aws-cli:latest \
  --restart=Never \
  --serviceaccount=s3-reader \
  --command -- sleep 3600

# Wait for the pod to be running
kubectl wait pod irsa-test --for=condition=Ready --timeout=60s

# Inspect the injected environment variables
kubectl exec irsa-test -- env | grep -E "AWS_ROLE_ARN|AWS_WEB_IDENTITY_TOKEN_FILE"

# Inspect the projected token mount
kubectl exec irsa-test -- ls -la /var/run/secrets/eks.amazonaws.com/serviceaccount/

# Call STS to confirm the pod is assuming the correct role
kubectl exec irsa-test -- aws sts get-caller-identity
```

The `Arn` field in the STS output should contain the role name you created, with an assumed-role session name matching the pod's ServiceAccount.

---

## Step 5 — Verify the S3 permission

```bash
# List S3 buckets (should work — s3:ListAllMyBuckets is in AmazonS3ReadOnlyAccess)
kubectl exec irsa-test -- aws s3 ls

# Attempt to create a bucket (should fail — no write permission)
kubectl exec irsa-test -- aws s3 mb s3://irsa-test-bucket-$(date +%s) 2>&1
```

You should see `Access Denied` on the create attempt, confirming that least-privilege is working.

---

## Step 6 — Test the scope restriction

Create a second ServiceAccount in a different namespace and verify it cannot assume the role:

```bash
kubectl create namespace test-ns
kubectl create serviceaccount impersonator --namespace test-ns

# Try to run a pod with the same role annotation but a different ServiceAccount
kubectl run irsa-bad \
  --image=amazon/aws-cli:latest \
  --restart=Never \
  --namespace test-ns \
  --overrides="{\"spec\":{\"serviceAccountName\":\"impersonator\",\"containers\":[{\"name\":\"irsa-bad\",\"image\":\"amazon/aws-cli:latest\",\"command\":[\"sleep\",\"3600\"],\"env\":[{\"name\":\"AWS_ROLE_ARN\",\"value\":\"arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-s3-reader\"},{\"name\":\"AWS_WEB_IDENTITY_TOKEN_FILE\",\"value\":\"/var/run/secrets/eks.amazonaws.com/serviceaccount/token\"}]}]}}" \
  -- sleep 3600

kubectl wait pod irsa-bad --namespace test-ns --for=condition=Ready --timeout=60s

# This should fail with "Not authorized to perform sts:AssumeRoleWithWebIdentity"
kubectl exec irsa-bad --namespace test-ns -- aws sts get-caller-identity 2>&1
```

The `sub` condition in the trust policy (`system:serviceaccount:default:s3-reader`) rejects tokens from any other ServiceAccount.

---

## Step 7 — Clean up

```bash
kubectl delete pod irsa-test
kubectl delete pod irsa-bad --namespace test-ns
kubectl delete serviceaccount s3-reader --namespace default
kubectl delete serviceaccount impersonator --namespace test-ns
kubectl delete namespace test-ns

aws iam detach-role-policy \
  --role-name "${CLUSTER_NAME}-s3-reader" \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess

aws iam delete-role --role-name "${CLUSTER_NAME}-s3-reader"

rm -f /tmp/irsa-trust-policy.json
```

---

## Knowledge Check

Answer without looking at the steps above:

1. What two environment variables does the EKS Pod Identity webhook inject into a pod when it detects a ServiceAccount annotation?
2. A pod is getting `AccessDenied` errors calling S3. The IAM role has `s3:GetObject` permission. What IRSA misconfiguration would cause this?
3. What is the purpose of the `StringEquals` condition on `aud` (`sts.amazonaws.com`) in the trust policy?
4. Without the `sub` condition in the trust policy, what security issue would exist?
5. How does AWS STS verify that the projected token is genuine and came from your cluster?
6. You need to give two different microservices different S3 permissions. Can they share one IRSA role? What is the recommended approach?
7. A developer removes the annotation from a ServiceAccount and the pod's IAM calls stop working. Restarting the pod fixes it. Why does a restart fix it?

<details>
<summary>Answers</summary>

1. `AWS_ROLE_ARN` (the ARN of the role to assume) and `AWS_WEB_IDENTITY_TOKEN_FILE` (the path to the projected token, typically `/var/run/secrets/eks.amazonaws.com/serviceaccount/token`).
2. The trust policy's `sub` condition likely does not match the actual ServiceAccount — wrong namespace, wrong name, or a typo. Alternatively, the annotation on the ServiceAccount might have the wrong role ARN.
3. The `aud` condition ensures the token was issued for the STS audience. Without it, a token intended for a different audience (e.g. the Kubernetes API server) could be used to assume the role.
4. Any pod in the cluster using any ServiceAccount could assume the role, as long as it can obtain a token. The `sub` scopes the role to a single ServiceAccount in a single namespace.
5. STS calls the OIDC provider's `jwks_uri` endpoint to fetch the public keys and verifies the token's signature. It also checks the `iss` (issuer) field in the token matches the registered OIDC provider URL.
6. Sharing one role gives both services the union of permissions. The recommended approach is one IAM role per ServiceAccount with only the permissions that service needs (least-privilege).
7. The webhook mutates the pod spec at creation time to inject the environment variables and token volume. Existing pods are not mutated. A new pod picks up the annotation (or lack thereof) at scheduling time.

</details>
