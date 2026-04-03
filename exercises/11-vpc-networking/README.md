# Exercise 11 — VPC Networking for EKS

## Learning Objectives

By the end of this exercise you will be able to:

- Explain why EKS requires a VPC with specific configuration
- Describe the role of public and private subnets in an EKS cluster
- Identify the subnet tags required for the AWS Load Balancer Controller
- Inspect VPC resources using the AWS CLI

---

## Background

EKS runs the control plane as a managed service in AWS-owned accounts. Your worker nodes run inside **your** VPC. The control plane communicates with worker nodes via cross-account ENIs (Elastic Network Interfaces) that AWS injects into your private subnets.

### Subnet split: public vs private

| Subnet type | What lives here | Internet access |
|---|---|---|
| **Public** | NAT Gateways, internet-facing load balancers | Direct via Internet Gateway |
| **Private** | Worker nodes, internal load balancers | Outbound-only via NAT Gateway |

Worker nodes run in private subnets so they are never directly reachable from the internet. The load balancer sits in the public subnet and forwards traffic inward.

### Required VPC settings

| Setting | Required value | Why |
|---|---|---|
| `enable_dns_support` | `true` | Nodes resolve internal AWS hostnames |
| `enable_dns_hostnames` | `true` | Nodes get resolvable DNS names; required for IRSA to work |

### Subnet tags EKS and the Load Balancer Controller rely on

| Tag | Value | Purpose |
|---|---|---|
| `kubernetes.io/cluster/<cluster-name>` | `shared` or `owned` | EKS discovers subnets it may use |
| `kubernetes.io/role/elb` | `1` | Load Balancer Controller places **internet-facing** ALBs/NLBs here |
| `kubernetes.io/role/internal-elb` | `1` | Load Balancer Controller places **internal** ALBs/NLBs here |

Without these tags, the AWS Load Balancer Controller cannot automatically select the correct subnets when you create a `Service` of type `LoadBalancer` or an `Ingress`.

---

## Prerequisites

```bash
# Set your cluster name — replace with the value from terraform.tfvars
export CLUSTER_NAME=my-eks-cluster
export AWS_REGION=eu-west-2

# Verify AWS credentials are active
aws sts get-caller-identity
```

---

## Step 1 — Inspect the VPC

```bash
# Find the VPC by name tag
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" \
  --query "Vpcs[0].VpcId" \
  --output text)

echo "VPC ID: $VPC_ID"

# Confirm DNS settings
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --query "EnableDnsSupport.Value"

aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames \
  --query "EnableDnsHostnames.Value"
```

Both should return `true`. If either is `false`, IRSA token validation will fail because nodes cannot resolve the OIDC issuer URL.

---

## Step 2 — Inspect the subnets

```bash
# List all subnets in the VPC with their AZ and CIDR
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query "Subnets[*].{Name:Tags[?Key=='Name']|[0].Value,AZ:AvailabilityZone,CIDR:CidrBlock,Public:MapPublicIpOnLaunch}" \
  --output table
```

You should see pairs of subnets per AZ — one public (`MapPublicIpOnLaunch: true`) and one private (`false`).

---

## Step 3 — Verify subnet tags

```bash
# Check public subnet tags (should have kubernetes.io/role/elb=1)
aws ec2 describe-subnets \
  --filters \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=tag:kubernetes.io/role/elb,Values=1" \
  --query "Subnets[*].{SubnetId:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}" \
  --output table

# Check private subnet tags (should have kubernetes.io/role/internal-elb=1)
aws ec2 describe-subnets \
  --filters \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query "Subnets[*].{SubnetId:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}" \
  --output table
```

If the `elb` query returns nothing, internet-facing load balancers will fail. If the `internal-elb` query returns nothing, internal services will fail to get a load balancer.

---

## Step 4 — Inspect the Internet Gateway

```bash
# Find the IGW attached to the VPC
aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
  --query "InternetGateways[0].{IGW:InternetGatewayId,State:Attachments[0].State}" \
  --output table
```

The state should be `available`. No IGW means public subnets have no internet access and NAT Gateways cannot provision EIPs.

---

## Step 5 — Confirm nodes are in private subnets

```bash
# Get the private subnet IDs
PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query "Subnets[*].SubnetId" \
  --output text)

echo "Private subnets: $PRIVATE_SUBNET_IDS"

# Check which subnet each node ENI is in
aws ec2 describe-instances \
  --filters \
    "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].{InstanceId:InstanceId,AZ:Placement.AvailabilityZone,SubnetId:SubnetId,PrivateIP:PrivateIpAddress}" \
  --output table
```

All node SubnetIds should match your private subnets — none should be in the public subnets.

---

## Step 6 — Clean up

No resources were created in this exercise. The VPC was inspected read-only.

---

## Knowledge Check

Answer without looking at the Terraform or the AWS console:

1. Why do worker nodes run in private subnets rather than public subnets?
2. What two tags must a subnet have for the AWS Load Balancer Controller to place an internet-facing load balancer in it?
3. A pod cannot resolve `s3.amazonaws.com`. You confirm the node's security group allows outbound. What VPC settings would you check next?
4. What happens if `enable_dns_hostnames` is `false` on the VPC?
5. You are deploying an internal `Service` of type `LoadBalancer` and the load balancer never becomes ready. What subnet tag is missing?
6. Why does each AZ need its own public subnet even though worker nodes are in private subnets?

<details>
<summary>Answers</summary>

1. Private subnets have no inbound internet route, so nodes are not directly reachable from the internet. Public subnets expose nodes to inbound connections and increase the attack surface.
2. `kubernetes.io/cluster/<cluster-name>=shared` (or `owned`) and `kubernetes.io/role/elb=1`.
3. Check `enable_dns_support=true` and `enable_dns_hostnames=true`. Also verify the route table has a default route to a NAT Gateway.
4. Nodes receive no DNS hostname, which breaks IRSA — pods call the OIDC token endpoint using the issuer URL and the hostname must resolve. It also breaks service discovery within the cluster.
5. `kubernetes.io/role/internal-elb=1` is missing on the private subnet.
6. Each AZ needs a NAT Gateway for private subnet egress, and NAT Gateways must be placed in a public subnet in the same AZ.

</details>
