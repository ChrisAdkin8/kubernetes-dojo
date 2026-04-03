# Exercise 12 — NAT Gateways and Route Tables

## Learning Objectives

By the end of this exercise you will be able to:

- Explain the traffic path from a pod to the internet
- Describe why one NAT Gateway per AZ is required for high availability
- Distinguish between the public and private route tables and their default routes
- Inspect NAT Gateways, Elastic IPs, and route tables with the AWS CLI

---

## Background

### Why private subnets need NAT

Worker nodes in private subnets have no direct internet route. They still need outbound internet access to:
- Pull container images from public registries (Docker Hub, ECR public gallery)
- Reach AWS APIs (EC2, ECR, SSM, CloudWatch, STS)
- Download OS updates

A **NAT Gateway** in a public subnet gives nodes outbound-only internet access. Traffic flows:

```
Pod → Node (private subnet) → NAT Gateway (public subnet) → Internet Gateway → Internet
```

Return traffic is allowed because NAT maintains state. Inbound connections from the internet are blocked — NAT is not bidirectional.

### One NAT Gateway per AZ

If all AZs route through a single NAT Gateway, a single-AZ failure kills all outbound internet for every node in every AZ. Each AZ must have its own NAT Gateway so a failure in one AZ only affects that AZ's nodes.

```
AZ-a nodes → NAT-GW-a (public-a) → IGW → Internet
AZ-b nodes → NAT-GW-b (public-b) → IGW → Internet
```

Each NAT Gateway requires an **Elastic IP** (EIP) — a static public IP that persists across NAT Gateway operations.

### Route tables

| Route table | Attached to | Default route |
|---|---|---|
| Public | Public subnets | `0.0.0.0/0 → Internet Gateway` |
| Private (per AZ) | Private subnets | `0.0.0.0/0 → NAT Gateway (same AZ)` |

A common mistake is attaching all private subnets to a single private route table. This works but means all private subnets share one NAT Gateway — defeating per-AZ HA.

---

## Prerequisites

```bash
export CLUSTER_NAME=my-eks-cluster
export AWS_REGION=eu-west-2

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" \
  --query "Vpcs[0].VpcId" \
  --output text)
echo "VPC: $VPC_ID"
```

---

## Step 1 — Inspect the Elastic IPs

```bash
# List EIPs tagged for this cluster
aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=${CLUSTER_NAME}-nat-eip-*" \
  --query "Addresses[*].{Name:Tags[?Key=='Name']|[0].Value,AllocationId:AllocationId,PublicIP:PublicIp,AssociationId:AssociationId}" \
  --output table
```

You should see one EIP per AZ. The `AssociationId` column will be populated when the EIP is assigned to a NAT Gateway.

---

## Step 2 — Inspect the NAT Gateways

```bash
# List NAT Gateways for this cluster
aws ec2 describe-nat-gateways \
  --filter "Name=tag:Name,Values=${CLUSTER_NAME}-nat-*" \
  --query "NatGateways[*].{Name:Tags[?Key=='Name']|[0].Value,NatGatewayId:NatGatewayId,State:State,SubnetId:SubnetId,PublicIP:NatGatewayAddresses[0].PublicIp}" \
  --output table
```

All NAT Gateways should be in `available` state. Each should be in a **public** subnet (verify the SubnetId against Step 2 of Exercise 11).

---

## Step 3 — Inspect the route tables

```bash
# List all route tables in the VPC
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query "RouteTables[*].{Name:Tags[?Key=='Name']|[0].Value,RouteTableId:RouteTableId}" \
  --output table
```

You should see:
- One public route table
- One private route table per AZ

---

## Step 4 — Verify the public route table

```bash
# Get the public route table ID
PUBLIC_RT_ID=$(aws ec2 describe-route-tables \
  --filters \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=tag:Name,Values=${CLUSTER_NAME}-rt-public" \
  --query "RouteTables[0].RouteTableId" \
  --output text)

echo "Public route table: $PUBLIC_RT_ID"

# Show its routes
aws ec2 describe-route-tables \
  --route-table-ids "$PUBLIC_RT_ID" \
  --query "RouteTables[0].Routes[*].{Destination:DestinationCidrBlock,Target:GatewayId,NATGateway:NatGatewayId,State:State}" \
  --output table
```

You should see:
- A local route for the VPC CIDR (`local`)
- A default route `0.0.0.0/0` pointing to an Internet Gateway (`igw-*`)

---

## Step 5 — Verify a private route table

```bash
# Get one of the private route tables (e.g. for AZ-a)
PRIVATE_RT_ID=$(aws ec2 describe-route-tables \
  --filters \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=tag:Name,Values=${CLUSTER_NAME}-rt-private-${AWS_REGION}a" \
  --query "RouteTables[0].RouteTableId" \
  --output text)

echo "Private route table (AZ-a): $PRIVATE_RT_ID"

aws ec2 describe-route-tables \
  --route-table-ids "$PRIVATE_RT_ID" \
  --query "RouteTables[0].Routes[*].{Destination:DestinationCidrBlock,Target:GatewayId,NATGateway:NatGatewayId,State:State}" \
  --output table
```

You should see:
- A local route for the VPC CIDR
- A default route `0.0.0.0/0` pointing to a NAT Gateway (`nat-*`) — **not** an IGW

---

## Step 6 — Confirm route table associations

```bash
# Show which subnets each route table is associated with
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query "RouteTables[*].{Name:Tags[?Key=='Name']|[0].Value,Associations:Associations[*].SubnetId}" \
  --output table
```

Each private subnet should be associated with only its AZ-local private route table. No private subnet should point to the public route table (that would expose nodes to inbound internet traffic).

---

## Step 7 — Trace a packet from pod to internet

Run a debug pod and verify it can reach the internet through NAT:

```bash
# Spin up a temporary pod
kubectl run net-debug --image=busybox:1.36 --restart=Never -it --rm -- /bin/sh
```

Inside the pod:
```sh
# Check the pod's IP (will be in the private subnet CIDR)
ip addr show eth0

# Trace the route — first hop will be the node, then NAT GW's private IP, then internet
traceroute -n 1.1.1.1

# Confirm outbound connectivity via NAT (the source IP seen externally is the EIP)
wget -qO- https://ifconfig.me
exit
```

The IP returned by `ifconfig.me` should match one of the EIPs from Step 1.

---

## Clean up

No AWS resources were created. Delete the debug pod if it is still running:

```bash
kubectl delete pod net-debug --ignore-not-found
```

---

## Knowledge Check

Answer without looking at the Terraform or AWS console:

1. A NAT Gateway is in `available` state but nodes in the same AZ cannot reach the internet. What route table problem would cause this?
2. You have two AZs but only one NAT Gateway. Describe the failure scenario if the NAT Gateway's AZ loses power.
3. What is the difference between an Elastic IP and a regular public IP on a NAT Gateway?
4. A pod's outbound traffic reaches the internet. What source IP does the destination server see — the pod IP, the node IP, or the EIP?
5. Why does a private subnet's route table point to a NAT Gateway instead of an Internet Gateway?
6. If you needed to allowlist your EKS nodes' egress IP in an external firewall, what do you allowlist?

<details>
<summary>Answers</summary>

1. The private subnet's route table either has no default route, or its default route points to the wrong NAT Gateway (one in a different AZ, or the IGW). Each private subnet's route table must have `0.0.0.0/0 → NAT Gateway in the same AZ`.
2. All nodes across both AZs route outbound traffic through the surviving NAT Gateway in the other AZ. Cross-AZ NAT traffic costs money and increases latency. If the sole NAT Gateway is in the failed AZ, all outbound connectivity is lost cluster-wide.
3. An Elastic IP is a static allocation that persists independently of the NAT Gateway. If the NAT Gateway is deleted and recreated, it reuses the same EIP. A regular public IP is ephemeral and changes on restart.
4. The EIP. The NAT Gateway translates the pod's private source IP to the EIP before traffic leaves the VPC.
5. An Internet Gateway provides two-way internet access. Routing private subnets via IGW would allow inbound internet connections directly to nodes. NAT only allows outbound-initiated sessions.
6. The Elastic IP addresses attached to the NAT Gateways — one per AZ. These are the source IPs that external systems observe.

</details>
