---
title: P0/P1 correctness fixes, part 2 — core exercises 02–18
created: 2026-09-14
status: draft # draft | reviewed | in-progress | done | superseded
research: ~/notes/research/2026-09-14-kubernetes-dojo-critical-review.md
idea: none
read-at: f086d6b
cite-repo: none
---

# P0/P1 correctness fixes, part 2 — core exercises 02–18

## Goal

Every step in exercises 02–18 that fails as written, or teaches something false, is corrected, so a learner can run each exercise verbatim, in order, on the cluster from part 1 (`2026-09-14-p0-p1-correctness-fixes-1-platform.md`, a prerequisite). The GPU track is part 3. The research note `~/notes/research/2026-09-14-kubernetes-dojo-critical-review.md` explains why.

## Decision

This spec takes option B, the research's Recommendation: fix the P0/P1 defects now, and move exercises 01–12 to kind later. It covers the exercise-content half of Recommendation steps 1–2. The rejected options are recorded in part 1. From the interview: exercises 01–12 are checked on a local kind cluster, and exercises 13–18 on the one EKS run shared with part 1.

## Background

Read at `f086d6b` on 2026-09-14. Square-bracket numbers are sources in the research note. The note is `status: final`, and borrowed claims its Verification table doesn't show as checked ([11]'s quote, [16], [17], [28]) are marked *(unverified)*. Part 1 lands first and adds lines to `eks/README.md`, so the one line this part cites in that file is also given by its text.

- **Exercise 02.** The sidecar already runs `mkdir -p /var/log` (`exercises/02-pods-and-containers/manifests/multi-container-pod.yaml:36-43`). That is the fix Step 6.4 asks the learner to make (`exercises/02-pods-and-containers/README.md:176-195`), so the promised CrashLoopBackOff (`:131`) never happens.
  - Step 6.5 execs into `log-sidecar` and lists `/shared` (`:224-231`). Only the init and app containers mount `shared-data` (`exercises/02-pods-and-containers/manifests/multi-container-pod.yaml:16-18,24-26`).
  - The comment "tails the nginx access log" (`:35`) is wrong, because the sidecar reads a file in its own filesystem. The research doesn't mention this.
  - The README jumps from Step 6 to Step 8 (`exercises/02-pods-and-containers/README.md:245`).
- **Cross-exercise links.** Exercise 05 sends learners to `../02-deployments/` (`exercises/05-services/README.md:33-37`, `:152`), but the Deployment `web-app` lives in `exercises/03-deployments/manifests/deployment.yaml:1-9`.
  - Exercise 05's clean-up deletes its `web-app-clusterip` Service (`exercises/05-services/README.md:151`; `exercises/05-services/manifests/clusterip-service.yaml:1-4`). Exercise 10's load generator then targets that deleted Service (`exercises/10-resource-management/README.md:173-177`).
  - Exercise 10's clean-up still uses `../02-deployments/` (`:198`), and Step 5 says "from exercise 02" (`:156`).
  - The HPA "requires the Metrics Server" (`exercises/10-resource-management/manifests/hpa.yaml:1-2`). So does `kubectl top` in exercise 12 (`exercises/12-troubleshooting/README.md:163-173`).
  - metrics-server is first installed in exercise 18, unpinned at `latest` (`exercises/18-autoscaling/README.md:66-88`, `:78`).
  - Exercise 04's PVCs name no StorageClass (`exercises/04-daemonsets-and-statefulsets/manifests/statefulset.yaml:49-56`). Part 1 W4 adds a default class on EKS; kind ships its own default *(assumption)*.
- **Exercise 11.**
  - **Ports.** `backend` runs nginx but is exposed with `--port=8080` (`exercises/11-network-policies/README.md:56-59`). The repo's other nginx workloads use port 80 (`:50-53`; `exercises/03-deployments/manifests/deployment.yaml:27-29`). `kubectl run --expose --port` gives the Service the same target port *(assumption)*, so `http://backend:8080` (`exercises/11-network-policies/README.md:72`, `:87`, `:105`, `:107`) reaches nothing. The allow policy also opens 8080 (`exercises/11-network-policies/manifests/allow-frontend-to-backend.yaml:21-23`).
  - **Egress.** Deny-all blocks Ingress and Egress (`exercises/11-network-policies/manifests/deny-all.yaml:15-18`). The allow file reopens only Ingress (`exercises/11-network-policies/manifests/allow-frontend-to-backend.yaml:14-15,38-39`) and DNS egress (`:59-67`). [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/) [11]: "both the egress policy on the source pod and the ingress policy on the destination pod need to allow the connection" *(unverified)*. So Step 3's "should work" lines (`exercises/11-network-policies/README.md:103-112`) stay blocked.
  - **Enablement.** Network policy is switched on by a CLI call with a hard-coded cluster name (`:34-42`). Part 1 W4 moves that into Terraform.
- **Exercises 13–18.** Five READMEs set `CLUSTER_NAME=my-eks-cluster`: `exercises/13-vpc-networking/README.md:50`, `exercises/14-nat-and-routing/README.md:56`, `exercises/15-eks-control-plane/README.md:66`, `exercises/16-oidc-and-irsa/README.md:91` and `exercises/17-managed-node-groups/README.md:62`. The default name is `k8s-dojo` (`eks/variables.tf:7-11`). Exercise 18 already reads the name from Terraform (`exercises/18-autoscaling/README.md:342`).
  - **Exercise 16.** It uses `kubectl run --serviceaccount` (`exercises/16-oidc-and-irsa/README.md:192-197`). [PR #108820](https://github.com/kubernetes/kubernetes/pull/108820) [13] removed that flag; the note's Verification table confirms this. The same README already sets `serviceAccountName` through `--overrides` (`:243`).
  - **Exercise 18, placeholders.** The ServiceAccount's role ARN uses the placeholder `CLUSTER_NAME` (`exercises/18-autoscaling/manifests/cluster-autoscaler.yaml:11-13`). The README table lists only `ACCOUNT_ID` and `YOUR_CLUSTER_NAME` (`exercises/18-autoscaling/README.md:427-432`), which matches `exercises/18-autoscaling/manifests/cluster-autoscaler.yaml:173-174`.
  - **Exercise 18, working directory.** `cd /tmp/autoscaler/vertical-pod-autoscaler` (`exercises/18-autoscaling/README.md:95-97`) leaves the shell outside the exercise. After that, `kubectl apply -f manifests/target-deployment.yaml` (`:123`) and `$(cd ../../eks ...)` (`:342`, `:411`) resolve under `/tmp`. The clean-up repeats the bare `cd` (`:531`) just before `:534`.
- **Wrong claims.**
  - `eks/README.md:192`, knowledge-check answer 6 (it starts "6. The OIDC provider allows"), says the VPC CNI injects the IRSA token. Exercise 16 already says the EKS Pod Identity webhook injects the token volume, `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE` (`exercises/16-oidc-and-irsa/README.md:82-84`), so the repo contradicts itself. [AWS re:Post](https://repost.aws/knowledge-center/eks-troubleshoot-irsa-errors) [16] backs the webhook *(unverified)*.
  - `exercises/06-configmaps-and-secrets/README.md:18` and `:150` say Secrets are not encrypted by default. [EKS envelope encryption](https://docs.aws.amazon.com/eks/latest/userguide/envelope-encryption.html) [17] says all Kubernetes API data is envelope-encrypted on 1.28+ *(unverified)*.

## Non-goals

- The GPU track (part 3) and the platform changes (part 1).
- Running 01–12 on kind as the documented path, and CI (a later spec). kind appears here only as the free test bed.
- Pinning the other `latest` images (`exercises/08-rbac/README.md:89`, `exercises/12-troubleshooting/manifests/oomkilled-pod.yaml:18`, `exercises/16-oidc-and-irsa/README.md:194`).
- Pod Identity, Karpenter, and VPA mode changes (P2).

## Design

All the changes are to README steps and manifests. Nothing changes structurally.

Every exercise reads the cluster name from Terraform, as exercise 18 already does. Every `cd` out of an exercise directory runs in a subshell. metrics-server is installed at a pinned version in exercise 10, and exercise 12 points back to it. Exercise 18 keeps its own check-then-install block, which is needed when it's run alone, but uses the same pinned URL.

The test beds:
- **kind:** a local cluster with a network-policy-enforcing kind version (S1), used for 02–12.
- **EKS:** the part 1 gate run, used for 04 (the StorageClass), 11 (the VPC CNI), and 13–18.

## Work items

### W1: Make exercise 02's CrashLoopBackOff real

- **Change:**
  - Delete `mkdir -p /var/log` from `exercises/02-pods-and-containers/manifests/multi-container-pod.yaml:41`, so the shipped manifest crashes as Step 5 says.
  - Mount `shared-data` at `/shared` in `log-sidecar`, so Step 6.5's `ls /shared` works and shows that a volume is shared across containers.
  - Correct the comment at `:35`.
  - Add `git checkout -- manifests/multi-container-pod.yaml` to Step 9, so the lab can be re-run.
  - Renumber Steps 8 and 9 (`exercises/02-pods-and-containers/README.md:245`, `exercises/02-pods-and-containers/README.md:267`) as Steps 7 and 8.
- **Files:** `exercises/02-pods-and-containers/manifests/multi-container-pod.yaml`, `exercises/02-pods-and-containers/README.md`
- **Done when:**
  - On kind, `kubectl apply -f manifests/multi-container-pod.yaml` gives `1/2` and `CrashLoopBackOff` within 3 minutes.
  - `kubectl logs multi-container-pod -c log-sidecar --previous` shows the `No such file or directory` error quoted at README Step 6.3 (see S2).
  - After making the Step 6.4 edit and re-applying, the pod shows `2/2 Running`, and `kubectl exec multi-container-pod -c log-sidecar -- cat /shared/message.txt` prints `Hello from init container`.
  - `grep -n '^## Step' exercises/02-pods-and-containers/README.md` lists Steps 1–8 with no gaps.

### W2: Fix the cross-exercise dependencies (04, 05, 10, 12, 18)

- **Change:**
  - **Exercise 04:** add a Prerequisites line: `kubectl get storageclass` must show one `(default)`, which part 1 W4 provides on EKS.
  - **Exercise 05:** point `exercises/05-services/README.md:33-37` and `exercises/05-services/README.md:152` at `../03-deployments/`.
  - **Exercise 10:**
    - Add a Prerequisites block that installs metrics-server from a pinned release URL (S3) and waits for `kubectl top nodes`.
    - In Step 5, re-apply `../05-services/manifests/clusterip-service.yaml` before the load generator.
    - Fix the wording at `exercises/10-resource-management/README.md:156`.
    - Point the clean-up at `../03-deployments/` and delete the Service.
  - **Exercise 12:** point the "requires Metrics Server" line (`exercises/12-troubleshooting/README.md:163`) at exercise 10's Prerequisites.
  - **Exercise 18:** replace the `latest` install at `exercises/18-autoscaling/README.md:78` with the same pinned URL.
- **Files:**
  - `exercises/04-daemonsets-and-statefulsets/README.md`
  - `exercises/05-services/README.md`
  - `exercises/10-resource-management/README.md`
  - `exercises/12-troubleshooting/README.md`
  - `exercises/18-autoscaling/README.md`
- **Done when:**
  - `git grep -n '02-deployments\|exercise 02' -- exercises/05-services exercises/10-resource-management` prints nothing.
  - `git grep -n 'releases/latest' exercises` prints nothing.
  - On kind, run exercise 03, then exercise 05's Steps 1–2, 5 and 6, then exercise 10's Prerequisites and Step 5, all verbatim (see S3 for a kind-only metrics-server flag). Skip exercise 05's Steps 3–4 on kind: the NodePort step needs a node IP, and the LoadBalancer never gets an address without cloud-provider-kind ([kind: LoadBalancer](https://kind.sigs.k8s.io/docs/user/loadbalancer/) [27]). `kubectl get hpa web-app-hpa` shows a numeric CPU value, not `<unknown>`, within 3 minutes. The `REPLICAS` column reaches 4 or more within 5 minutes of starting the load generator. The Deployment starts with 3 replicas (`exercises/03-deployments/manifests/deployment.yaml:9`), so only a real scale-up passes. This assumes one `wget` loop pushes the nginx pods above 70% of their 50m request (`exercises/03-deployments/manifests/deployment.yaml:46`) *(assumption)*; S6 checks it.
  - `grep -n -i storageclass exercises/04-daemonsets-and-statefulsets/README.md` shows the new Prerequisites line. The EKS check that the PVCs bind is part 1 W4's Done when.

### W3: Fix exercise 11's ports and egress

- **Change:**
  - Expose `backend` on port 80, and change the four `backend:8080` URLs to `http://backend`.
  - Change the allow-policy port to 80.
  - Add two egress policies to `allow-frontend-to-backend.yaml`: `tier=frontend` may send to `tier=backend` on TCP 80, and `tier=backend` may send to `tier=database` on TCP 5432.
  - Replace the CLI enablement block (`exercises/11-network-policies/README.md:34-42`) with a check that Terraform already enabled it: `aws eks describe-addon ... --query addon.configurationValues`. Keep the Calico and Cilium links.
  - Add one sentence to Step 2: under deny-all, name lookups fail first, and Step 4 explains why.
- **Files:** `exercises/11-network-policies/README.md`, `exercises/11-network-policies/manifests/allow-frontend-to-backend.yaml`
- **Done when:**
  - `git grep -n 8080 exercises/11-network-policies` prints nothing.
  - On a network-policy-enforcing kind cluster (S1), running Steps 1–4 verbatim gives these results:
    - Step 1: both commands exit 0.
    - Step 2: both commands print `BLOCKED`.
    - Step 3: the two "should work" commands exit 0, and the two "should be blocked" commands print `BLOCKED`.
    - Step 4: the name resolves.
  - The same results on the EKS run.

### W4: Make exercises 13–18 run as written

- **Change:**
  - In the five READMEs, replace `export CLUSTER_NAME=my-eks-cluster` with `export CLUSTER_NAME=$(terraform -chdir=../../eks output -raw cluster_name)`, and delete the "replace with the value from terraform.tfvars" comment above it (for example, `exercises/13-vpc-networking/README.md:49`).
  - **Exercise 16:** replace `--serviceaccount=s3-reader` with `--overrides='{"spec":{"serviceAccountName":"s3-reader"}}'`.
  - **Exercise 18:**
    - Change the placeholder at `exercises/18-autoscaling/manifests/cluster-autoscaler.yaml:13` to `YOUR_CLUSTER_NAME`. Update the comments at `exercises/18-autoscaling/manifests/cluster-autoscaler.yaml:11` and `exercises/18-autoscaling/manifests/cluster-autoscaler.yaml:173` to say that the README's `sed` step fills in both placeholders.
    - The image at `exercises/18-autoscaling/manifests/cluster-autoscaler.yaml:163` is part 1 W1's to bump to the cluster's minor version. This item doesn't touch it, but its EKS check needs it.
    - Replace the manual edit in Step 12 with `sed -e "s/ACCOUNT_ID/${ACCOUNT_ID}/" -e "s/YOUR_CLUSTER_NAME/${CLUSTER_NAME}/g" manifests/cluster-autoscaler.yaml | kubectl apply -f -`, so the repo file stays unedited, and make the clean-up use the same pipe with `kubectl delete -f -`.
    - Wrap both VPA `cd` lines in subshells: `(cd /tmp/autoscaler/vertical-pod-autoscaler && ./hack/vpa-up.sh)`.
- **Files:**
  - `exercises/13-vpc-networking/README.md`
  - `exercises/14-nat-and-routing/README.md`
  - `exercises/15-eks-control-plane/README.md`
  - `exercises/16-oidc-and-irsa/README.md`
  - `exercises/17-managed-node-groups/README.md`
  - `exercises/18-autoscaling/README.md`
  - `exercises/18-autoscaling/manifests/cluster-autoscaler.yaml`
- **Done when:**
  - `git grep -n 'my-eks-cluster\|--serviceaccount' exercises` prints nothing.
  - `grep -n 'role/YOUR_CLUSTER_NAME-cluster-autoscaler' exercises/18-autoscaling/manifests/cluster-autoscaler.yaml` matches line 13, and `grep -n 'role/CLUSTER_NAME' exercises/18-autoscaling/manifests/cluster-autoscaler.yaml` prints nothing.
  - `grep -nE '^cd ' exercises/18-autoscaling/README.md` prints nothing.
  - EKS run: exercise 16 Step 4 prints `AWS_ROLE_ARN=`.
  - EKS run: exercise 18's Prerequisites (including the VPA install), Step 1, Steps 10–12 and Step 15, run verbatim in one shell starting in `exercises/18-autoscaling`, print no `No such file or directory`. The Cluster Autoscaler pod reaches `Running`, and after Step 15, `aws iam get-role --role-name k8s-dojo-cluster-autoscaler` fails with `NoSuchEntity`.

### W5: Correct the IRSA and Secrets-encryption claims

- **Change:**
  - Rewrite `eks/README.md:192` (answer 6; after part 1 lands, find it with `grep -n '^6\. The OIDC provider' eks/README.md`) to match `exercises/16-oidc-and-irsa/README.md:82-84`: the EKS Pod Identity webhook mutates the Pod to add `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE` and the projected token volume ([research](https://repost.aws/knowledge-center/eks-troubleshoot-irsa-errors) [16] *(unverified)*).
  - Rewrite `exercises/06-configmaps-and-secrets/README.md:18` and `:150`. On EKS 1.28+, Secrets are envelope-encrypted at rest by default ([research](https://docs.aws.amazon.com/eks/latest/userguide/envelope-encryption.html) [17] *(unverified)*). Name the key's ownership only if S5 finds it on that page. Anyone with `get secret` can still read them, and base64 is encoding, not encryption.
- **Files:** `eks/README.md`, `exercises/06-configmaps-and-secrets/README.md`
- **Done when:**
  - `git grep -n 'VPC CNI injects\|not encrypted by default\|base64-encoded (not encrypted)' -- eks exercises` prints nothing.
  - `grep -n 'webhook' eks/README.md` shows the rewritten answer.

## Effort

| Item | Estimate | Depends on |
|---|---|---|
| W1 | 1 h plus S2 | — |
| W2 | 2 h plus S3, S6 | part 1 W4 (ex 04 on EKS) |
| W3 | 2 h plus S1, S4 | part 1 W4 (VPC CNI) |
| W4 | 2 h | part 1 W1 (autoscaler image) for its EKS check |
| W5 | 30 min plus S5 | — |

These are estimated from reading the code, so trust the ordering more than the numbers. The kind checks cost nothing; the EKS checks ride on the part 1 gate run.

## Spike questions

- **S1. Which kind version enforces NetworkPolicy out of the box?** The research says kind has a built-in NetworkPolicy implementation, whose DNS bug was fixed in October 2024 ([kind #3713](https://github.com/kubernetes-sigs/kind/issues/3713) [28] *(unverified)*). To check: `kind create cluster` with the current release, apply `deny-all.yaml`, and confirm a `wget` between two pods times out.
- **S2. Does `busybox:1.36` lack `/var/log`, and does the shell exit non-zero without the `mkdir`?** Run `docker run --rm busybox:1.36 sh -c 'touch /var/log/access.log; tail -f /var/log/access.log'; echo $?` and expect a non-zero exit. If it doesn't crash, W1 needs a different deliberate fault.
- **S3. What is the current metrics-server release, and does it need `--kubelet-insecure-tls` on kind?** Run `gh release view -R kubernetes-sigs/metrics-server --json tagName`, then install it on kind and check `kubectl top nodes`. Record the flag as a kind-only note, for the later kind spec.
- **S4. Do `nginx:1.27-alpine` and `postgres:16-alpine` ship `nc -z` and `wget -T`?** Run `docker run --rm nginx:1.27-alpine nc 2>&1 | head -5` and `docker run --rm postgres:16-alpine wget --help 2>&1 | head -3`. If not, switch the tests to a `busybox:1.36` pod carrying the right tier label.
- **S5. Do the two AWS pages say what W5 will teach?** Read the [IRSA troubleshooting page](https://repost.aws/knowledge-center/eks-troubleshoot-irsa-errors) for the webhook quote and the two variable names, and the [envelope encryption page](https://docs.aws.amazon.com/eks/latest/userguide/envelope-encryption.html) for the 1.28+ default and who owns the key. Alternatively, run `/research finish ~/notes/research/2026-09-14-kubernetes-dojo-critical-review.md "[16] and [17]"` to have them verified by name. This takes ten minutes and costs nothing.
- **S6. Does exercise 10's one `wget` loop push `web-app` above its HPA target?** On kind, run exercise 10 Step 5 and watch `kubectl top pods -l app=web-app`. If per-pod CPU stays under about 38m (the 70% target on the 50m request, plus the HPA's default 10% tolerance *(assumption)*), strengthen the load in W2: run several loops, or a `busybox` pod running `while true; do wget -q -O- ...; done &` four times. This takes ten minutes on kind.

## Risks and rollback

- **Part 1 must land first.** W3's README no longer enables network policy, so running exercise 11 on a cluster from before part 1 shows nothing blocked. That's the pre-existing failure mode, which knowledge-check answer 2 already covers (`exercises/11-network-policies/README.md:148`).
- **Rollback.** Every item is docs or manifests. Revert per item.

## Open questions

- None.
