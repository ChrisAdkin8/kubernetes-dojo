---
title: Correctness fixes, round 2, part 3 — AWS exercises 13–18
created: 2026-10-09
status: draft # draft | reviewed | in-progress | done | superseded
research: ~/notes/research/2026-10-09-kubernetes-dojo-critical-analysis.md
idea: none
read-at: 5119a98
cite-repo: none
---

# Correctness fixes, round 2, part 3 — AWS exercises 13–18

## Goal

This part fixes every step in exercises 13–18 that fails as written, that leaves AWS resources changed, or that teaches something false. Afterwards, a learner can run each exercise verbatim, in any region, on the cluster from part 1.

Part 1 (`2026-10-09-correctness-fixes-round-2-1-platform.md`) is a prerequisite. Parts 2 and 4 cover exercises 01–12 and the GPU track. The [research note](~/notes/research/2026-10-09-kubernetes-dojo-critical-analysis.md) explains why.

## Decision

For exercises 13–18, this spec takes option A from the research's Recommendation. It fixes the P0/P1 defects and every false statement now, runs the result on EKS before any part merges, and then writes the kind and CI spec that the 2026-09-14 specs deferred.

The rejected options:
- **B (CI and kind first)** leaves the data-loss and cost defects in place while CI is built, and kind can't run the EKS-only steps.
- **Doing nothing** leaves every learner meeting the defects.

Choices made at interview (2026-10-09):
- The scope is the P0/P1 defects, plus every lower-severity item that is a failing step or a false statement. Version currency, drills, the kind move, CI and repo tidying go to later specs.
- EFS becomes an opt-in Terraform setting.
- Teardown gets a pre-destroy script.
- Each GPU exercise scales its own nodes up at the start and down at the end.

## Background

Read at `5119a98` on 2026-10-09. Outside facts without a research source number were read at the linked revision that day; "offline" means reproduced locally without AWS.

**Region (W1)**
- Exercises 13–17 hard-code `export AWS_REGION=eu-west-2`: `exercises/13-vpc-networking/README.md:50`, `exercises/14-nat-and-routing/README.md:57`, `exercises/15-eks-control-plane/README.md:67`, `exercises/16-oidc-and-irsa/README.md:92` and `exercises/17-managed-node-groups/README.md:63`.
- The region is a variable (`eks/variables.tf:1-5`), and `eks/outputs.tf:1-35` has no region output. Part 1 W2 adds one.
- Exercise 18 sets no region. Steps 10, 11 and 15 read only the cluster name before calling `aws` (`exercises/18-autoscaling/README.md:341-344`, `:410-416`, `:522-523`).
  - `AWS_REGION` "overrides" `AWS_DEFAULT_REGION` and the profile's `region` ([AWS CLI environment variables](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html) ([research](~/notes/research/2026-10-09-kubernetes-dojo-critical-analysis.md) [31])) *(unverified)*. Without it, exercise 18 queries the profile's region.
  - There, `OIDC_PROVIDER` comes back empty, and the trust policy names `oidc-provider/` (`exercises/18-autoscaling/README.md:387`).
- Exercise 14 Step 5 looks for `${CLUSTER_NAME}-rt-private-${AWS_REGION}a` (`exercises/14-nat-and-routing/README.md:145`). Route tables are named after the AZ list (`eks/modules/vpc/routes.tf:37`), which part 1 W2 derives, so a region with no `a` zone matches nothing.

**Commands that fail (W2)**
- **Exercise 15 Step 5, flags.** It combines `--log-stream-name-prefix` with `--order-by LastEventTime` (`exercises/15-eks-control-plane/README.md:159-160`). With `LastEventTime`, "you cannot specify" the prefix ([DescribeLogStreams](https://docs.aws.amazon.com/AmazonCloudWatchLogs/latest/APIReference/API_DescribeLogStreams.html) (research [13])) *(unverified)*.
- **Exercise 15 Step 5, output.** It pipes `--output text` into `python3 -m json.tool` (`exercises/15-eks-control-plane/README.md:172-173`). Two records come out tab-separated on one line, and offline `printf '{"verb":"get"}\t{"verb":"list"}\n' | python3 -m json.tool` exits 1 with `Extra data`. The comment says "last 10" above `--limit 5` (`:167`, `:171`).
- **Exercise 15 Step 6** takes `accessEntries[0]` (`exercises/15-eks-control-plane/README.md:190-193`). EKS creates entries for "managed node group" roles ([access entries](https://docs.aws.amazon.com/eks/latest/userguide/creating-access-entries.html) (research [24])) *(unverified)*, named `<cluster>-node-group-role` and `<cluster>-<key>-node-group-role` here (`eks/modules/node_group/iam.tf:8`, `eks/main.tf:63`). Those entries have no policies, so when one comes first the table is empty *(assumption: the list's order)*.
- **Exercise 17 Step 6** pipes JSON into `python3 - << 'EOF'` (`exercises/17-managed-node-groups/README.md:171-179`). The heredoc replaces stdin, and offline the script fails with `JSONDecodeError: Expecting value`.
- **Exercise 18, VPA install.** It clones the autoscaler repo's default branch into `/tmp/autoscaler` (`exercises/18-autoscaling/README.md:95-96`), which fails on a second run. The clean-up (`:534`) needs that clone to still exist. VPA keeps release branches "for the most recent three minor releases (1.8, 1.7, 1.6)" and installs one by checking it out ([installation.md#L21](https://github.com/kubernetes/autoscaler/blob/vpa-release-1.8/vertical-pod-autoscaler/docs/installation.md#L21), [#L49](https://github.com/kubernetes/autoscaler/blob/vpa-release-1.8/vertical-pod-autoscaler/docs/installation.md#L49)).
- **Exercise 18, load generator and clean-up.**
  - Step 5 reruns the load generator without stopping it (`exercises/18-autoscaling/README.md:230`), so Step 8's reuse (`:313`) gets `AlreadyExists`.
  - Step 8 deletes the HPA (`:321`), so the clean-up's `kubectl delete -f manifests/hpa.yaml` (`:527`) fails.
- **Exercise 18, expected outputs.** Step 2 shows only CPU (`exercises/18-autoscaling/README.md:146-149`), though the HPA also targets memory (`exercises/18-autoscaling/manifests/hpa.yaml:22-27`). Step 13 asks for 20 pods of 500m (`exercises/18-autoscaling/README.md:460`, `:474`) and promises more nodes (`:491`), but the group stops at `node_max_count = 4` (`eks/variables.tf:95-99`), so some pods stay Pending.

**Demos (W3)**
- **Exercise 16 Step 6.** The `impersonator` ServiceAccount has no annotation (`exercises/16-oidc-and-irsa/README.md:236`), and its `--overrides` sets the two variables but mounts no token (`:243`). So the CLI fails before STS is asked *(assumption: botocore reads the token file first)*, the promised rejection (`:248`) never appears, and the `sub` condition (`:252`) goes untested.
- **Exercise 18 Step 8** sets `Auto` (`exercises/18-autoscaling/README.md:309-311`) while the HPA exists; it is deleted only in the warning after the step (`exercises/18-autoscaling/README.md:319-322`).
  - The Deployment has one replica (`exercises/18-autoscaling/manifests/target-deployment.yaml:9`), and the updater's `--min-replicas` "is set to 2" by default ([VPA FAQ](https://github.com/kubernetes/autoscaler/blob/vpa-release-1.8/vertical-pod-autoscaler/docs/faq.md) (research [20])) *(unverified)*. So the pod is evicted only if the HPA scales up while VPA updates: the conflict the warning forbids *(assumption)*.
  - `updatePolicy.minReplicas` "Overrides global '--min-replicas' flag" ([types.go#L198-L200](https://github.com/kubernetes/autoscaler/blob/vpa-release-1.8/vertical-pod-autoscaler/pkg/apis/autoscaling.k8s.io/v1/types.go#L198-L200)).
- **VPA modes.** VPA 1.8 marks `"Auto"` deprecated, "equivalent to `"Recreate"`", and says to use "Recreate", "Initial", or "InPlaceOrRecreate" ([quickstart.md#L18-L22](https://github.com/kubernetes/autoscaler/blob/vpa-release-1.8/vertical-pod-autoscaler/docs/quickstart.md#L18-L22) (research [19])) *(unverified)*.
  - The objective and the mode table teach three modes, ending with `Auto` (`exercises/18-autoscaling/README.md:10`, `:47-53`).
  - Answer 7 pairs `Auto` with a `minAvailable: 1` PDB for a singleton (`:573`). With one replica, that PDB allows no disruption, so the updater can never evict *(assumption: the updater evicts through the Eviction API)*.

**Clean-up and IAM (W4)**
- **Node group size.** The Cluster Autoscaler changes the ASG's desired capacity, and Step 15 (`exercises/18-autoscaling/README.md:519-543`) never resets it.
  - Terraform ignores `desired_size` (`eks/modules/node_group/node_group.tf:85-89`), and EKS "periodically syncs the managed node group's scaling configuration to match the actual Auto Scaling group values" ([managed node groups](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html) (research [7])) *(unverified)*.
  - So the group stays at up to 4 nodes (`eks/variables.tf:95-99`), about $34 a month each ($68.91 for two at `README.md:236`), or it shrinks to `node_min_count = 1` (`eks/variables.tf:89-93`).
- **Write permissions.** Step 10 grants `SetDesiredCapacity` and `TerminateInstanceInAutoScalingGroup` on `"Resource": ["*"]` (`exercises/18-autoscaling/README.md:370-375`), in a single-quoted policy (`:349`) that can't expand `${CLUSTER_NAME}`.
  - Upstream says to restrict them "by either specifying Auto Scaling Group ARNs … or using tag based conditionals" ([README.md#L29-L32](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.36.1/cluster-autoscaler/cloudprovider/aws/README.md#L29-L32) (research [28])) *(unverified)*.
  - Auto Scaling accepts `aws:ResourceTag/key-name` conditions ([Auto Scaling IAM](https://docs.aws.amazon.com/autoscaling/ec2/userguide/control-access-using-iam.html)) *(unverified)*.
- **Trust policy.** It checks `sub` only (`exercises/18-autoscaling/README.md:391-393`), though exercise 16 teaches `aud` alongside it (`exercises/16-oidc-and-irsa/README.md:149`, answer 3 at `:293`).

**False explanations (W5)** are listed with their sources in W5's table.

## Non-goals

- Exercises 01–12 (part 2), the GPU track (part 4) and the platform (part 1).
- Version currency, for a later spec: regional NAT gateways, EKS Pod Identity, `InPlaceOrRecreate` as the taught mode, the aws-auth deprecation, the autoscaler's `securityContext` and RBAC parity, and pinning `amazon/aws-cli:latest` (`exercises/16-oidc-and-irsa/README.md:194`, `:240`).
- Exercise 17 answer 4 (`NotReady` causes): reading can't settle it.
- The kind move and CI.

## Design

- **Region.** Exercises read the region the way they read the cluster name: `export AWS_REGION=$(terraform -chdir=../../eks output -raw region)`, from part 1 W2. Exercise 18 repeats it wherever it re-reads the cluster name (Steps 10, 11, 15), as it uses several terminals (`exercises/18-autoscaling/README.md:163`).
- **VPA without the HPA.** Exercise 18's VPA part runs without the HPA, in `Recreate` mode with `minReplicas: 1`.
- **Scoped writes.** The autoscaler's write actions apply only to ASGs tagged `k8s.io/cluster-autoscaler/<cluster>=owned`, which Step 11 makes sure of. The clean-up deletes the autoscaler before resetting the node group.
- **Test beds.** These exercises need AWS, so the live checks run in part 1's round-2 EKS run, not on kind.

## Work items

### W1: Region from Terraform in 13–18

- **Change:**
  - **13–17.** Replace `export AWS_REGION=eu-west-2` with `export AWS_REGION=$(terraform -chdir=../../eks output -raw region)` at the five lines in Background.
  - **18.** Add the same line after each `CLUSTER_NAME=` line (`exercises/18-autoscaling/README.md:341`, `:410`, `:522`).
  - **14 Step 5** (`exercises/14-nat-and-routing/README.md:141-149`). Replace the AZ-`a` lookup, and say "the first AZ" where it says "AZ-a". Every zone in the list has a private subnet and a route table named after it (`eks/modules/vpc/subnets.tf:24-29`, `eks/modules/vpc/routes.tf:28-37`), so the lookup works in any order; sorting only makes the pick stable:

    ```bash
    FIRST_AZ=$(aws ec2 describe-subnets \
      --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
      --query "sort_by(Subnets, &AvailabilityZone)[0].AvailabilityZone" --output text)
    PRIVATE_RT_ID=$(aws ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${CLUSTER_NAME}-rt-private-${FIRST_AZ}" \
      --query "RouteTables[0].RouteTableId" --output text)
    ```
- **Files:** the READMEs of exercises 13–18.
- **Done when:**
  - `git grep -n -F -e 'AWS_REGION=eu-west-2' -e 'rt-private-${AWS_REGION}a' -- exercises/1[3-8]-*` prints nothing.
  - `git grep -c -F 'export AWS_REGION=$(terraform -chdir=../../eks output -raw region)' -- 'exercises/1[3-8]-*/README.md'` prints `<path>:1` for each of 13–17 and `<path>:3` for 18.
  - The Step 5 query is checked live, in the round-2 EKS run below.
  - **Round-2 EKS run**, in a fresh shell with `AWS_DEFAULT_REGION=us-east-1`: exercise 18 Steps 10–12 run verbatim and the autoscaler pod reaches `Running`, and exercise 14 Step 5 prints a `0.0.0.0/0` route to a `nat-` gateway.

### W2: Commands that fail as written

- **Change:**
  - **15 Step 5** (`exercises/15-eks-control-plane/README.md:155-174`) becomes:

    ```bash
    # The five most recent audit records of the last five minutes, one per line
    aws logs tail "/aws/eks/${CLUSTER_NAME}/cluster" \
      --log-stream-name-prefix kube-apiserver-audit --since 5m --format short | tail -n 5

    # One record, pretty-printed
    aws logs filter-log-events --log-group-name "/aws/eks/${CLUSTER_NAME}/cluster" \
      --log-stream-name-prefix kube-apiserver-audit \
      --start-time $(( ($(date +%s) - 300) * 1000 )) --max-items 1 \
      --query 'events[0].message' --output text | python3 -m json.tool
    ```
  - **15 Step 6** (`exercises/15-eks-control-plane/README.md:190-193`): `--query "accessEntries[?!contains(@, 'node-group-role')] | [0]"`, with a comment that it skips the node roles' entries.
  - **17 Step 6** (`exercises/17-managed-node-groups/README.md:169-180`): `kubectl get nodes -o custom-columns=NAME:.metadata.name,ALLOCATABLE:.status.allocatable.pods,CAPACITY:.status.capacity.pods`.
  - **18 VPA install.** Before each VPA subshell (`exercises/18-autoscaling/README.md:95-96`, `:534`), run `[ "$(git -C /tmp/autoscaler rev-parse --abbrev-ref HEAD 2>/dev/null)" = vpa-release-1.8 ] || { rm -rf /tmp/autoscaler; git clone --depth 1 --branch vpa-release-1.8 https://github.com/kubernetes/autoscaler.git /tmp/autoscaler; }`, which also replaces a stale clone of another branch.
  - **18 load generator.** Step 5 ends with `kubectl delete pod load-generator` (`:230`). Step 8 runs Step 3's command afresh, and deletes the pod after the evictions (`:313`).
  - **18 Step 2's expected output** (`:146-149`) shows `cpu: 0%/50%, memory: <n>%/70%`.
  - **18 Step 13** (`:449-495`) says the group stops at `node_max_count` (4 by default), so some pods stay Pending.
  - **18 clean-up** (`:526-528`): `--ignore-not-found` on the three `kubectl delete -f` lines and on the autoscaler's `kubectl delete -f -` (`:529`). Add `2>/dev/null || true` after `vpa-down.sh` (`:534`) and the IAM `detach-role-policy`, `delete-role` and `delete-policy` calls (`:538-542`), so a second run prints no error.
- **Files:** the READMEs of exercises 15, 17 and 18.
- **Done when:**
  - `git grep -n -F -e 'order-by LastEventTime' -e 'python3 - <<' -- exercises/15-eks-control-plane exercises/17-managed-node-groups` prints nothing.
  - `grep -c -F -- '--branch vpa-release-1.8' exercises/18-autoscaling/README.md` prints 2.
  - **Offline, Step 5 pipe:** `printf '{"verb":"get"}\n' | python3 -m json.tool` exits 0, where the two-record form exits 1.
  - The Step 6 query and the custom columns are checked live, in the round-2 EKS run below.
  - **Round-2 EKS run:**
    - 15 Step 5 prints a record with a `verb` key, and Step 6 lists at least one access policy;
    - 17 Step 6 prints `17` in both columns for each node;
    - running 18's Prerequisites and clean-up twice in one shell prints no `already exists` and no `NoSuchEntity`.

### W3: Demos that test what they claim

- **Change:**
  - **16 Step 6** (`exercises/16-oidc-and-irsa/README.md:230-252`):
    - Set `ROLE_ARN` again (Step 3 sets it at `:175`).
    - Run `kubectl annotate serviceaccount impersonator --namespace test-ns "eks.amazonaws.com/role-arn=${ROLE_ARN}"`.
    - Start `irsa-bad` with `--overrides='{"spec":{"serviceAccountName":"impersonator"}}' --command -- sleep 3600`.
    - Explain why it fails: the webhook injects a real token for `system:serviceaccount:test-ns:impersonator`, which the `sub` condition (`:148`) rejects.
  - **18 Step 8** (`exercises/18-autoscaling/README.md:304-322`), renamed "Switch VPA to Recreate mode":
    - start with `kubectl delete hpa php-apache --ignore-not-found`, moved up from the warning, which becomes an explanation;
    - patch with `{"spec":{"updatePolicy":{"updateMode":"Recreate","minReplicas":1}}}`, with one sentence on `minReplicas`: once the HPA is gone, the Deployment keeps the replica count the HPA last set, which may be 1, and `minReplicas: 1` lets the updater evict even then.
  - **18's objective, note and table** (`:10`, `:32`, `:47-53`): the modes are `Off`, `Initial` and `Recreate`. One line says `Auto` is a deprecated alias of `Recreate`, and that VPA 1.8 also has `InPlaceOrRecreate`.
  - **The comment at `exercises/18-autoscaling/manifests/vpa.yaml:14`** says "Recreate".
  - **18's knowledge check.**
    - Questions and answers 3 and 4 (`exercises/18-autoscaling/README.md:551-552`, `:565-567`) say `Recreate` for `Auto`.
    - Answer 7 (`:573`) becomes: `Recreate` with `minReplicas: 1` if a brief restart is acceptable, otherwise `Initial`. It also says not to put a `minAvailable: 1` PDB on a single replica, because it blocks every eviction.
- **Files:** the READMEs of exercises 16 and 18, and `exercises/18-autoscaling/manifests/vpa.yaml`.
- **Done when:**
  - `git grep -n -e 'overrides=.*AWS_ROLE_ARN' -- exercises/16-oidc-and-irsa` prints nothing, and `grep -c 'annotate serviceaccount impersonator' exercises/16-oidc-and-irsa/README.md` prints 1.
  - `git grep -n -F 'updateMode":"Auto' -- exercises/18-autoscaling` prints nothing.
  - `awk '/^kubectl delete hpa php-apache/{d=NR} /"updateMode":"Recreate"/{r=NR} END{exit !(d && r && d < r)}' exercises/18-autoscaling/README.md` exits 0.
  - **Round-2 EKS run, exercise 16:** `irsa-bad`'s `env` shows `AWS_ROLE_ARN=`, and its `aws sts get-caller-identity` fails with `AccessDenied` and `AssumeRoleWithWebIdentity` in the message.
  - **Round-2 EKS run, exercise 18:** within 15 minutes of starting Step 8's load, `kubectl get events --field-selector reason=EvictedByVPA` lists an event (spike question 1), and the new pod's CPU request equals the VPA's `Target`.

### W4: Exercise 18 clean-up and the autoscaler's IAM

- **Change:**
  - **Step 10 policy** (`exercises/18-autoscaling/README.md:346-377`): write it with an unquoted heredoc to `/tmp/ca-policy.json`. The ten read actions stay as they are. The two write actions get `"Condition": {"StringEquals": {"aws:ResourceTag/k8s.io/cluster-autoscaler/${CLUSTER_NAME}": "owned"}}`. Pass it as `--policy-document file:///tmp/ca-policy.json`.
  - **Step 10 trust policy:** add `\"${OIDC_PROVIDER}:aud\": \"sts.amazonaws.com\"` to `StringEquals` (`:391-393`).
  - **Step 11 check** (`:414-422`): stop with a message if `ASG_NAME` is empty or holds more than one name. After `create-or-update-tags`, `aws autoscaling describe-tags --filters Name=auto-scaling-group,Values="$ASG_NAME" Name=key,Values="k8s.io/cluster-autoscaler/${CLUSTER_NAME}" --query 'Tags[0].Value' --output text` must print `owned`.
  - **Step 15** (`:519-543`):
    1. Delete the autoscaler first (the `sed … | kubectl delete -f -` line, `:529`).
    2. Run `aws eks update-nodegroup-config --cluster-name "$CLUSTER_NAME" --nodegroup-name general --scaling-config desiredSize="$ORIG_DESIRED"`.
       - Step 10 first saves `ORIG_DESIRED=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name general --query nodegroup.scalingConfig.desiredSize --output text)`.
       - The autoscaler also discovers a `gpu` group: the tags at `eks/modules/node_group/node_group.tf:91-94` go on every group, including those from `gpu_node_groups` (`eks/main.tf:46-51`). So if `aws eks list-nodegroups` shows one, set its desired size to 0 too.
       - Then run `aws eks wait nodegroup-active --cluster-name "$CLUSTER_NAME" --nodegroup-name general` and `kubectl get nodes`.
    3. End with `rm -f /tmp/ca-policy.json`.
- **Files:** `exercises/18-autoscaling/README.md`.
- **Done when:**
  - Pasting Step 10's heredoc into bash or zsh with `CLUSTER_NAME=k8s-dojo` writes a file that `python3 -m json.tool` accepts, and `jq -r '.Statement[1].Condition.StringEquals | keys[]' /tmp/ca-policy.json` prints `aws:ResourceTag/k8s.io/cluster-autoscaler/k8s-dojo`.
  - `grep -c ':aud' exercises/18-autoscaling/README.md` prints 1.
  - `awk '/^## Step 15/{s=1} s && /cluster-autoscaler\.yaml.*kubectl delete -f -/{d=NR} s && /update-nodegroup-config/{u=NR} END{exit !(d && u && d < u)}' exercises/18-autoscaling/README.md` exits 0.
  - **Round-2 EKS run:** Step 13 still adds nodes with no `AccessDenied` in the autoscaler's log (spike question 2), and after Step 15 `aws eks describe-nodegroup --cluster-name k8s-dojo --nodegroup-name general --query nodegroup.scalingConfig.desiredSize` prints the value Step 10 saved: 2 with the default `node_desired_count` (`eks/variables.tf:83-87`).

### W5: False explanations and answers

- **Change:** Rewrite each passage to match its source. Sources on docs.aws.amazon.com and kubernetes.io below are *(unverified)*: the research note has no Verification table.

| Where | Now says | Change to | Source |
|---|---|---|---|
| `exercises/13-vpc-networking/README.md:32`, `:81`, answer 4 at `:186` | DNS hostnames are needed for IRSA, and service discovery breaks without them | Without both settings, nodes can't register and the private endpoint's zone fails. STS validates IRSA tokens (`exercises/16-oidc-and-irsa/README.md:34`), and CoreDNS serves in-cluster names | [network requirements](https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html), [endpoint](https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html) (research [21], [22]) |
| `exercises/13-vpc-networking/README.md:9`, `:34-42`, question and answer 2 at `:174`, `:184` | The tags are for the AWS Load Balancer Controller, and "two tags must" be set | Load balancers go in subnets tagged `kubernetes.io/role/elb` or `internal-elb`; only the controller at 2.1.1 or earlier needs the cluster tag. Nothing installs that controller: Services use the cloud provider (`exercises/05-services/manifests/loadbalancer-service.yaml:8`), and nothing serves `Ingress` | [network requirements](https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html) (research [21]) |
| `exercises/14-nat-and-routing/README.md:92`; `exercises/17-managed-node-groups/README.md:39` | "Step 2 of Exercise 11"; "cluster IAM role from Exercise 13" | Exercise 13; Exercise 15 | renumbering at `f086d6b` |
| answer 4 at `exercises/14-nat-and-routing/README.md:230` | NAT "translates the pod's private source IP" | The VPC CNI first SNATs off-VPC pod traffic to the node's IP (`AWS_VPC_K8S_CNI_EXTERNALSNAT` defaults to `false`); NAT then maps that to the EIP | [VPC CNI README#L231-L237](https://github.com/aws/amazon-vpc-cni-k8s/blob/e458542b9eb7b692d3e077a7f63a1c35baad89ed/README.md#L231-L237) |
| answer 2 at `exercises/14-nat-and-routing/README.md:228` | "the surviving NAT Gateway in the other AZ" | With one NAT Gateway (`:218`), losing its AZ cuts egress for every node | `:218` |
| question and answer 3 at `exercises/14-nat-and-routing/README.md:219`, `:229` | A NAT Gateway may have "a regular public IP" | A public NAT Gateway always has an EIP (`:40`); the ephemeral case is an instance's public IP | `:40` |
| answer 4 at `exercises/15-eks-control-plane/README.md:257`, and the related line `:36` | A private zone resolves `kubernetes.default.svc.cluster.local` | EKS's private zone resolves the API endpoint's hostname, and "doesn't appear in your account's Route 53 resources"; CoreDNS resolves `kubernetes.default.svc` | [endpoint](https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html) (research [22]) |
| `exercises/16-oidc-and-irsa/README.md:126` | "The thumbprint authenticates" the provider's certificate | IAM checks it against "our library of trusted root certificate authorities"; thumbprints cover providers outside it | [IAM thumbprints](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc_verify-thumbprint.html) |
| `exercises/16-oidc-and-irsa/README.md:212` | The session name matches the ServiceAccount | The CLI names it `botocore-session-<epoch seconds>` | [botocore#L824](https://github.com/boto/botocore/blob/f5506411e36783687a41be838472a8c47e52e3dc/botocore/credentials.py#L824), inherited by the web-identity fetcher at [#L953](https://github.com/boto/botocore/blob/f5506411e36783687a41be838472a8c47e52e3dc/botocore/credentials.py#L953) |
| question 7 at `exercises/16-oidc-and-irsa/README.md:286` | Removing the annotation breaks a running pod | Invert it: adding one doesn't reach a running pod, and a restart does, as answer 7 (`:297`) says | `:297` |
| answer 7 at `exercises/17-managed-node-groups/README.md:250` | Scale-in drains "respecting `PodDisruptionBudgets`" | PDBs "aren't respected when … reducing the desired node count" | [managed node groups](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html) (research [7]) |
| answer 5 at `exercises/17-managed-node-groups/README.md:248` | Pod IPs are pods plus "1 node IP" per node | The CNI keeps a spare ENI's addresses free (`WARM_ENI_TARGET` defaults to 1), so budget each node's ENI addresses: 3 × 6 = 18 on t3.medium *(assumption: the ENI sizes behind the 17-pod limit at `:182`)*, where 20 pods per node can't fit | [VPC CNI README#L277-L284](https://github.com/aws/amazon-vpc-cni-k8s/blob/e458542b9eb7b692d3e077a7f63a1c35baad89ed/README.md#L277-L284) |
| answer 2 at `exercises/17-managed-node-groups/README.md:245` | At `maxSize` the autoscaler logs `MaxNodeProvisionTime` | That is how long it waits for a node (15m); at `maxSize` the pods just stay Pending | [FAQ.md#L1082](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.36.1/cluster-autoscaler/FAQ.md#L1082) |
| `exercises/18-autoscaling/README.md:58` | The default expander is `random` | `least-waste` is the default | [FAQ, 1.36.1](https://github.com/kubernetes/autoscaler/blob/cluster-autoscaler-1.36.1/cluster-autoscaler/FAQ.md) (research [29]) |
| `exercises/18-autoscaling/README.md:407`; `exercises/18-autoscaling/manifests/cluster-autoscaler.yaml:175` | The tags "may need adding"; they are "set by the EKS Terraform module" | EKS tags managed node group resources for the autoscaler; the Terraform tags sit on the node group (`eks/modules/node_group/node_group.tf:91-94`). Step 11 keeps `create-or-update-tags` so W4's condition sees `owned` | [managed node groups](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html) (research [7]) |
| answer 8 at `exercises/18-autoscaling/README.md:575` | A 0-second scale-down window means "dropped connections" | The risk is flapping: the window exists "to restrict the flapping of replica count" | [Kubernetes HPA](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/) |

- **Files:** the READMEs of exercises 13–18, and `exercises/18-autoscaling/manifests/cluster-autoscaler.yaml`.
- **Done when:**
  - Before the change, this prints a hit for each of the 20 phrases; after it, it prints nothing:

    ```bash
    git grep -n -F \
      -e 'required for IRSA' -e 'cannot resolve the OIDC issuer' \
      -e 'Load Balancer Controller cannot' -e 'two tags must' \
      -e 'kubernetes.default.svc.cluster.local' -e 'respecting `PodDisruptionBudgets`' \
      -e 'default: `random`' -e 'set by the EKS Terraform module' \
      -e 'Step 2 of Exercise 11' -e 'role from Exercise 13' -e 'matching the pod' \
      -e 'MaxNodeProvisionTime' -e 'regular public IP' -e 'surviving NAT Gateway' \
      -e 'thumbprint authenticates' -e 'removes the annotation' -e 'dropped connections' \
      -e '1 node IP' -e "translates the pod's private source IP" -e 'may need adding' \
      -- exercises/13-vpc-networking exercises/14-nat-and-routing exercises/15-eks-control-plane \
         exercises/16-oidc-and-irsa exercises/17-managed-node-groups exercises/18-autoscaling
    ```
  - Each new passage carries its row's key phrase, which `git grep -n -F -e '<phrase>' -- exercises/<nn>-*` finds:
    - 13: `can't register`, `2.1.1`;
    - 14: `Step 2 of Exercise 13`, `AWS_VPC_K8S_CNI_EXTERNALSNAT`, `cuts egress`, `always has`;
    - 15: `Route 53 resources`;
    - 16: `trusted root certificate authorities`, `botocore-session-`;
    - 17: `role from Exercise 15`, `aren't respected`, `WARM_ENI_TARGET`, `max-node-provision-time`;
    - 18: `least-waste`, `EKS tags`, `flapping`.

## Effort

| Item | Estimate | Depends on |
|---|---|---|
| W1 | 1 h | part 1 W2 (the `region` output) |
| W2 | 2 h | — |
| W3 | 1.5 h | — |
| W4 | 1 h | W1 (Step 10's region line) |
| W5 | 2 h | W4 (the Step 11 wording) |

These estimates come from reading the code, so trust the ordering more than the numbers. The EKS checks run in part 1's round-2 EKS run.

## Spike questions

1. How long after Step 8's load starts does the updater evict `php-apache` with `minReplicas: 1`? Experiment: in the round-2 EKS run, time from starting the load to the first `EvictedByVPA` event. If it's over 15 minutes, W3's Done when and Step 8 use the observed time.
2. After Step 11, does the general group's ASG carry `k8s.io/cluster-autoscaler/<cluster>=owned`, so W4's condition lets the autoscaler scale? Experiment: in the round-2 EKS run, `aws autoscaling describe-tags --filters Name=auto-scaling-group,Values=<asg>` after Step 11, then Step 13 with no `AccessDenied` in the autoscaler's log.
3. Does `vpa-up.sh` from `vpa-release-1.8` install cleanly on Kubernetes 1.36? Experiment: in the round-2 EKS run, after exercise 18's Prerequisites, `kubectl -n kube-system get deploy vpa-recommender vpa-updater vpa-admission-controller` shows all three available.

## Risks and rollback

- **W1 needs part 1 W2.** Until then, `terraform output -raw region` fails with `Output "region" not found`, so W1 lands after part 1.
- **The W4 condition can block scaling.** If the ASG's tag value isn't `owned`, the autoscaler can't scale. Spike question 2 checks this; rollback is to remove the `Condition` block.
- **Rollback.** It's all README and manifest text: revert per item.

## Open questions

- Verifier round 2 found that W4's Step 15 `awk` check could never pass once W2 adds `--ignore-not-found` to the same line. The check was fixed after that round, and no third round re-checked it.
