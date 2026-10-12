---
title: Correctness fixes, round 2, part 2 — core exercises 01–12
created: 2026-10-09
status: draft # draft | reviewed | in-progress | done | superseded
research: ~/notes/research/2026-10-09-kubernetes-dojo-critical-analysis.md
idea: none
read-at: 5119a98
cite-repo: none
---

# Correctness fixes, round 2, part 2 — core exercises 01–12

## Goal

This part corrects every step in exercises 01–12 and the root README's Quick Reference that fails as written or teaches something false, so a learner can run them verbatim on the part 1 cluster and trust them.

Part 1 (`docs/specs/2026-10-09-correctness-fixes-round-2-1-platform.md`) is a prerequisite, because W4 reads the `region` output it adds. Parts 3 and 4 cover exercises 13–18 and the GPU track. The [research](~/notes/research/2026-10-09-kubernetes-dojo-critical-analysis.md) explains why.

## Decision

This spec takes option A from the research's Recommendation, for exercises 01–12:
1. Fix the P0/P1 defects and every false statement now.
2. Run the result on EKS before any part merges.
3. Then write the kind and CI spec that the 2026-09-14 specs deferred.

Rejected:
- **B (CI and kind first)** leaves the data-loss and cost defects in place while CI is built, and kind can't run the EKS-only steps.
- **Doing nothing** leaves every learner meeting them.

Choices made at the 2026-10-09 interview:
- The scope is the P0/P1 defects plus every lower-severity item that is a failing step or a false statement. Version currency, drills, the kind move, CI and repo tidying go to later specs.
- EFS becomes an opt-in Terraform setting.
- Teardown gets a pre-destroy script.
- Each GPU exercise scales its own nodes up at the start and down at the end.

Only the first choice affects this part.

## Background

Read at `5119a98` on 2026-10-09. Pages cited by URL alone were read on that date but sit outside the research note, so their claims are *(unverified)*.

**Commands that fail as written**
- **Quick Reference, `set image`.** `kubectl create deployment web --image=nginx:1.27-alpine` (`README.md:187`) names its container `nginx`, after the image's last path segment ([create_deployment.go#L250-L259](https://github.com/kubernetes/kubernetes/blob/v1.36.5/staging/src/k8s.io/kubectl/pkg/cmd/create/create_deployment.go#L250-L259)), but the next command is `kubectl set image deployment/web web=nginx:1.26-alpine` (`README.md:196`). Offline, `kubectl set image -f <that Deployment> web=… --local` fails with `unable to find container named "web"`, and `nginx=…` works *(assumption: an unrecorded local run; W1's offline check repeats it)*.
- **Exercise 06 Step 5** edits `LOG_LEVEL` (`exercises/06-configmaps-and-secrets/README.md:110-115`), then reads `app.properties` (`:120`).
  - The Pod mounts the whole ConfigMap at `/etc/config` (`exercises/06-configmaps-and-secrets/manifests/pod-with-config.yaml:35-39`), so each key is its own file.
  - The `app.properties` key (`exercises/06-configmaps-and-secrets/manifests/configmap.yaml:12-15`) never changes.
- **Exercise 08 Step 5** filters on `?(@.subjects[*].name=="pod-reader-sa")` (`exercises/08-rbac/README.md:142-145`).
  - client-go fails a comparison whose left side yields more than one value: "can only compare one element at a time" ([jsonpath.go#L525-L526](https://github.com/kubernetes/kubernetes/blob/v1.36.5/staging/src/k8s.io/client-go/util/jsonpath/jsonpath.go#L525-L526)).
  - Every cluster binds `system:public-info-viewer` to two groups ([policy.go#L699](https://github.com/kubernetes/kubernetes/blob/v1.36.5/plugin/pkg/auth/authorizer/rbac/bootstrappolicy/policy.go#L699)).
- **Exercise 05 Step 3** reaches the NodePort through `<NODE_EXTERNAL_IP>` (`exercises/05-services/README.md:90-96`), but the nodes sit in private subnets (`eks/modules/node_group/node_group.tf:54`).
- **Exercise 12 Step 4** has two problems.
  - It runs `dig @10.96.0.10` (`exercises/12-troubleshooting/README.md:144`). `eks/modules/eks_cluster/cluster.tf` sets no service CIDR, so EKS uses "10.100.0.0/16 or 172.20.0.0/16" ([EKS API](https://docs.aws.amazon.com/eks/latest/APIReference/API_KubernetesNetworkConfigRequest.html) ([research](~/notes/research/2026-10-09-kubernetes-dojo-critical-analysis.md) [14])) *(unverified)*.
  - It targets `web-app-clusterip` (`exercises/12-troubleshooting/README.md:147`), which the clean-ups of exercises 05 (`exercises/05-services/README.md:151`) and 10 (`exercises/10-resource-management/README.md:220`) delete.
- **Exercise 12 Step 7 and answer 3.**
  - Step 7's `kubectl delete pod finalizer-pod` (`exercises/12-troubleshooting/README.md:224`) never returns: `--wait` defaults to `true` and "waits for finalizers" ([delete_flags.go#L155](https://github.com/kubernetes/kubernetes/blob/v1.36.5/staging/src/k8s.io/kubectl/pkg/cmd/delete/delete_flags.go#L155)).
  - Answer 3 reads a cgroup v1 path (`exercises/12-troubleshooting/README.md:261`), but AL2023 uses cgroup v2 ([AL2023](https://docs.aws.amazon.com/linux/al2023/ug/cgroupv2.html) ([research](~/notes/research/2026-10-09-kubernetes-dojo-critical-analysis.md) [33])) *(unverified)*.
- **Exercise 09 Step 3** greps `kubectl describe pod` for `Affinity` (`exercises/09-scheduling/README.md:88`). `describePod` prints QoS class, node selectors, tolerations and spread constraints, and no affinity ([describe.go#L868-L871](https://github.com/kubernetes/kubernetes/blob/v1.36.5/staging/src/k8s.io/kubectl/pkg/describe/describe.go#L868-L871)).

**Expected results that don't happen**
- **Exercise 10 Step 4** expects refusals "beyond the limit of 20" (`exercises/10-resource-management/README.md:170`).
  - Every Pod gets the LimitRange's 256Mi default limit (`exercises/10-resource-management/manifests/resource-quota.yaml:45-47`) against a 4Gi `limits.memory` quota (`:24`), so 16 Pods fill it (4096 ÷ 256).
  - Counting Step 3's `default-limits-pod` (`exercises/10-resource-management/README.md:133-143`), `pod-16` is refused first, on `limits.memory`, not `pods` (`exercises/10-resource-management/manifests/resource-quota.yaml:26`).
- **Exercise 10 Step 5.** The quota Pods Step 4 starts (`exercises/10-resource-management/README.md:164-166`) stay up into Step 5 (`:174`), since only Step 6's clean-up (`:215`) removes them.
  - A t3.medium holds 17 Pods ([eni-max-pods.txt#L1317](https://github.com/aws/amazon-vpc-cni-k8s/blob/e458542b9eb7b692d3e077a7f63a1c35baad89ed/misc/eni-max-pods.txt#L1317)), and the cluster defaults to two (`eks/variables.tf:80`, `:86`).
  - About 11 system Pods *(assumption: default add-on replicas)*, 16 quota Pods, 3 `web-app` and the load generator leave the HPA (`exercises/10-resource-management/manifests/hpa.yaml:15`) about 3 slots. W2's EKS check settles it.
- **Exercise 07 Step 4** expects "the original timestamp" (`exercises/07-persistent-storage/README.md:108`), but each start overwrites it (`exercises/07-persistent-storage/manifests/pod-with-pvc.yaml:15`).
- **Exercise 01 Step 1** expects static Pods like `kube-apiserver-controlplane` (`exercises/01-kubernetes-architecture/README.md:46-52`). EKS runs the control plane itself; the add-ons are vpc-cni, coredns, kube-proxy and aws-ebs-csi-driver (`eks/modules/eks_cluster/addons.tf:7`, `:21`, `:32`, `:40`).
- **Exercise 03 Step 6** pauses, then sets `nginx:1.27-alpine` (`exercises/03-deployments/README.md:186-191`). That image is already running after the Step 5 rollback (`exercises/03-deployments/manifests/deployment.yaml:27`), so nothing rolls out.
- **Exercise 09 Step 4** taints one node (`exercises/09-scheduling/README.md:98-99`). The tolerating Pod (`exercises/09-scheduling/manifests/taints-tolerations.yaml:15-20`) "can schedule on either node" (`exercises/09-scheduling/README.md:117`), so its placement proves nothing.

**Security-relevant claims**
- **Exercise 05's NLB.** The README says the annotation requests "an internal NLB" (`exercises/05-services/README.md:102`).
  - The manifest sets only `aws-load-balancer-type: "nlb"` (`exercises/05-services/manifests/loadbalancer-service.yaml:8`). It's `aws-load-balancer-internal` that "Indicates that the load balancer should be internal" ([cloud-provider-aws](https://cloud-provider-aws.sigs.k8s.io/service_controller/) ([research](~/notes/research/2026-10-09-kubernetes-dojo-critical-analysis.md) [8])) *(unverified)*.
  - The public subnets carry `kubernetes.io/role/elb` (`eks/modules/vpc/subnets.tf:16`), so the NLB is internet-facing.
- **Exercise 06's `stringData`.** Answer 1 says `stringData` doesn't appear in `get -o yaml` (`exercises/06-configmaps-and-secrets/README.md:148`).
  - Step 1 applies (`:28`) a manifest with `DB_PASSWORD` in `stringData` (`exercises/06-configmaps-and-secrets/manifests/secret.yaml:12-17`).
  - Client-side apply records the file in `kubectl.kubernetes.io/last-applied-configuration` ([declarative config](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/) ([research](~/notes/research/2026-10-09-kubernetes-dojo-critical-analysis.md) [9])) *(unverified)*.
  - `kubectl create` writes that annotation only with `--save-config`, which defaults to `false` ([helpers.go#L526](https://github.com/kubernetes/kubernetes/blob/v1.36.5/staging/src/k8s.io/kubectl/pkg/cmd/util/helpers.go#L526)).

**Exercise 11**

From [Network policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/) ([research](~/notes/research/2026-10-09-kubernetes-dojo-critical-analysis.md) [32]) *(unverified)*:
- **Isolation.** The README says "Traffic not matching any policy is dropped" (`exercises/11-network-policies/README.md:17`). The docs say "By default, a pod is non-isolated for egress; all outbound connections are allowed".
- **`policyTypes`.** The README says `policyTypes` "must explicitly include" a type (`:24`). The docs say "If no policyTypes are specified … Ingress will always be set and Egress will be set if the NetworkPolicy has any egress rules."
- **Answer 2** blames a CNI that doesn't enforce when traffic "is still blocked" (`:141`, `:150`), but such a CNI blocks nothing. The docs: "both the egress policy on the source pod and the ingress policy on the destination pod need to allow the connection."
- **The DNS rule.** `allow-dns-egress` has `ports` but no `to` (`exercises/11-network-policies/manifests/allow-frontend-to-backend.yaml:99-116`), so it opens port 53 to anywhere. Answer 5 says it targets kube-dns (`exercises/11-network-policies/README.md:153`).
- **`deny-all.yaml`'s header** says the VPC CNI doesn't enforce policies (`exercises/11-network-policies/manifests/deny-all.yaml:4-6`). Terraform turns enforcement on (`eks/modules/eks_cluster/addons.tf:12-13`).
- **Region.** `--region "${AWS_REGION:-eu-west-2}"` (`exercises/11-network-policies/README.md:42`) ignores the region in `terraform.tfvars`.

**Other false statements** *(unverified: pages read on 2026-10-09, outside the research note)*
- **Exercise 02.**
  - READY is given as "running containers" (`exercises/02-pods-and-containers/README.md:56`), although answer 5 counts ready ones (`:300`).
  - STATUS is called the phase (`:57`), and `Failed` is "at least one container exited non-zero" (`:264`).
  - [Pod lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/): `Failed` means "All containers in the Pod have terminated, and at least one container has terminated in failure"; "CrashLoopBackOff may appear in the Status field".
- **Exercise 01.**
  - `get all` is said to list "every object" (`exercises/01-kubernetes-architecture/README.md:112-118`).
  - Answer 10's "node's Pod CIDR" (`:269`) is wrong here: the VPC CNI "assigns a private IPv4 or IPv6 address from your VPC to each Pod" ([EKS](https://docs.aws.amazon.com/eks/latest/userguide/managing-vpc-cni.html)).
- **Exercise 04, answer 4:** "You must delete them manually" (`exercises/04-daemonsets-and-statefulsets/README.md:217`). In fact `persistentVolumeClaimRetentionPolicy` "controls if and how PVCs are deleted" ([StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)).
- **Exercise 06, answer 5,** cites a "cache TTL (~30 seconds)" (`exercises/06-configmaps-and-secrets/README.md:152`).
  - The kubelet's change-detection default is `Watch`, and `syncFrequency` defaults to `1m` ([kubelet config](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/)).
  - A "subPath volume mount will not receive ConfigMap updates" ([ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/)).
- **Exercise 03's `100%`/`0` row** promises "overlap if surge > 0" with surge 0 (`exercises/03-deployments/README.md:56`). For `Recreate`, "Successful removal is awaited before any Pod of the new revision is created" ([Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)).
- **Exercise 10's Burstable row** reads "requests < limits" (`exercises/10-resource-management/README.md:31`). [Pod QoS](https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/): the Pod isn't Guaranteed, and "At least one Container in the Pod has a memory or CPU request or limit".
- **Exercise 12's objectives** promise `kubectl events` (`exercises/12-troubleshooting/README.md:8`), but the steps run only `kubectl get events` (`:183`, `:189`).
- **The Quick Reference** has two problems.
  - It pairs `--sort-by` with `-w` (`README.md:211`), and kubectl warns that "--sort-by will be ignored for watch events received" ([get.go#L275](https://github.com/kubernetes/kubernetes/blob/v1.36.5/staging/src/k8s.io/kubectl/pkg/cmd/get/get.go#L275)).
  - Its prompt line (`README.md:173`) prints literally under `zsh -f`, macOS's default shell *(assumption: an unrecorded local run; W5's check tests the replacement)*.

## Non-goals

- Parts 1, 3 and 4.
- Image pins, including the `nginx:1.27-alpine` refresh.
- Native sidecars, EndpointSlices, `--record`, and version wording such as `exercises/09-scheduling/README.md:202`.
- Exercise 09's soft zone preference (`exercises/09-scheduling/manifests/affinity.yaml:26-32`).
- CKA/CKAD coverage, drills, and moving 01–12 to kind.

## Design

Each fix keeps its exercise's lesson.
- **What EKS hides is named,** against kubeadm and kind, which show it.
- **Expected outputs match this cluster.**
- **Commands stay copy-pasteable.**
- **Placeholders are filled with `sed` into `kubectl apply -f -`.** This is exercise 18's pattern, and it leaves repo files unedited.

The checks are:
- `grep` checks;
- offline `kubectl` runs;
- kind v0.33.0, which commit `d27b56c`'s message names ("Checked on kind v0.33.0 (Kubernetes 1.37)"), with `kind create cluster`'s default one-node config. Whether its built-in network policy support enforces is the September spike S1 (`docs/specs/2026-09-14-p0-p1-correctness-fixes-2-core-exercises.md:172`) *(assumption: it does)*. Before any exercise 11 check, apply `deny-all.yaml` and confirm that Step 2 prints `BLOCKED`;
- the round-2 EKS run in part 1's Design.

## Work items

### W1: Commands that fail as written

- **Change:**
  - **`README.md:196`:** `kubectl set image deployment/web nginx=nginx:1.26-alpine`, with a comment that `create deployment` names the container after the image.
  - **Exercise 06 Step 5:**
    - Read `/etc/config/LOG_LEVEL` instead of `app.properties`.
    - Add `kubectl exec app-with-config -- printenv LOG_LEVEL`, which still prints `info` and so shows the env-var note (`exercises/06-configmaps-and-secrets/README.md:123`).
  - **Exercise 08 Step 5:**

    ```
    kubectl get rolebindings,clusterrolebindings --all-namespaces \
      -o custom-columns='KIND:.kind,NAMESPACE:.metadata.namespace,NAME:.metadata.name,SUBJECTS:.subjects[*].name' \
      | grep -E '^KIND|pod-reader-sa'
    ```
  - **Exercise 05 Step 3:**
    - Say the nodes are private.
    - Test from a Pod:
      - set `NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')`;
      - run `kubectl run test-pod --image=busybox:1.36 --restart=Never -it --rm -- wget -qO- "http://${NODE_IP}:30080"`.
  - **Exercise 12 Step 4:**
    - Open with `kubectl apply -f ../03-deployments/manifests/deployment.yaml -f ../05-services/manifests/clusterip-service.yaml`, and add `kubectl delete -f ../05-services/manifests/clusterip-service.yaml -f ../03-deployments/manifests/deployment.yaml --ignore-not-found` to Step 8.
    - Replace `dig @10.96.0.10 …` with `grep nameserver /etc/resolv.conf` (the kube-dns Service IP) and `dig web-app-clusterip.default.svc.cluster.local`.
  - **Exercise 12, other two:**
    - Step 7: `kubectl delete pod finalizer-pod --wait=false`.
    - Answer 3: `cat /sys/fs/cgroup/memory.current`.
  - **Exercise 09 Step 3:** `kubectl get pods -l app=affinity-demo -o jsonpath='{.items[0].spec.affinity}{"\n"}'`, noting that `describe` doesn't print affinity.
- **Files:**
  - `README.md`
  - `exercises/05-services/README.md`
  - `exercises/06-configmaps-and-secrets/README.md`
  - `exercises/08-rbac/README.md`
  - `exercises/09-scheduling/README.md`
  - `exercises/12-troubleshooting/README.md`
- **Done when:**
  - This prints nothing:

    ```
    git grep -n -e '@10.96.0.10' -e 'memory.usage_in_bytes' -e 'NODE_EXTERNAL_IP' -e 'subjects\[\*\]\.name==' -e 'Affinity"' -e 'deployment/web web=' -- README.md exercises
    ```
  - **Offline,** with an empty `KUBECONFIG`: `kubectl create deployment web --image=nginx:1.27-alpine --dry-run=client -o yaml > /tmp/web.yaml`, then `kubectl set image -f /tmp/web.yaml nginx=nginx:1.26-alpine --local -o jsonpath='{.spec.template.spec.containers[0].image}'`, prints `nginx:1.26-alpine`. Neither command needs a cluster; if either tries to reach one, that's a spec problem to report.
  - **On kind:**
    - **Exercise 06 Step 5,** with `kubectl patch configmap app-config --type merge -p '{"data":{"LOG_LEVEL":"debug"}}'` in place of the edit: within 90 s, `cat /etc/config/LOG_LEVEL` prints `debug` and `printenv LOG_LEVEL` prints `info`.
    - **Exercise 08 Step 5** prints a `RoleBinding … pod-reader-binding` row and a `ClusterRoleBinding … cluster-reader-binding` row. The old command fails with `can only compare one element at a time`.
    - **Exercise 05 Step 3's `wget`** prints the nginx page.
    - **Exercise 12, run after exercise 05's clean-up:**
      - Step 4 resolves `web-app-clusterip`.
      - Step 7's delete returns at once, and the Pod shows `Terminating`.
  - **Round-2 EKS run:**
    - the exercise 05 and 12 checks above;
    - `kubectl run cg --image=busybox:1.36 --restart=Never --rm -it -- cat /sys/fs/cgroup/memory.current` prints a number.

### W2: Expected results that don't happen

- **Change:**
  - **Exercise 10, `exercises/10-resource-management/README.md:170`:** "Forbidden from `pod-16` on (`exceeded quota … limits.memory`). The quota allows 20 Pods, but each gets the LimitRange's 256Mi limit, and 16 fill the 4Gi." Also:
    - `wc -l` prints 17: `default-limits-pod`, `pod-1` to `pod-15` and the header line;
    - end Step 4 with `kubectl delete pods --all -n team-alpha`, to free node Pod slots.
  - **Exercise 07:** make `exercises/07-persistent-storage/manifests/pod-with-pvc.yaml:15-16` write only when the file is absent: `[ -f /data/timestamp.txt ] || { date > /data/timestamp.txt; echo "Node: $NODE_NAME" >> /data/timestamp.txt; }`. Step 4 also runs `head -3 /data/log.txt`.
  - **Exercise 01 Step 1:** kubeadm and kind run the control plane as static Pods. EKS runs it outside your nodes, so `kube-system` holds only `aws-node`, `kube-proxy`, `coredns` and the `ebs-csi-*` Pods.
  - **Exercise 03 Step 6:**
    1. Pause.
    2. Run `set image … web=nginx:1.26-alpine`.
    3. Show `kubectl get deploy web-app -o jsonpath='{.spec.paused}'` and `kubectl get rs -l app=web-app`: nothing scales.
    4. Resume.
    5. Run `kubectl rollout status deployment/web-app`.
  - **Exercise 09 Step 4:** pin both Pods to `$NODE`.
    - `no-toleration` gets `--overrides="{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"$NODE\"}}}"`.
    - The manifest gains `nodeSelector: {kubernetes.io/hostname: TAINTED_NODE}`, applied with `sed "s/TAINTED_NODE/$NODE/" manifests/taints-tolerations.yaml | kubectl apply -f -`. Its header comment (`exercises/09-scheduling/manifests/taints-tolerations.yaml:1-8`), which now says only to taint a node first, is updated to say to apply the file through that `sed`.
    - Expect `no-toleration` `Pending` (untolerated taint) and `tolerating-pod` `Running`.
- **Files:**
  - `exercises/01-kubernetes-architecture/README.md`
  - `exercises/03-deployments/README.md`
  - `exercises/07-persistent-storage/README.md`
  - `exercises/07-persistent-storage/manifests/pod-with-pvc.yaml`
  - `exercises/09-scheduling/README.md`
  - `exercises/09-scheduling/manifests/taints-tolerations.yaml`
  - `exercises/10-resource-management/README.md`
- **Done when:**
  - `grep -n -e 'limit of 20' -e 'can schedule on either node' -e 'You should see Pods named with the pattern' -r exercises` prints nothing.
  - **On kind:**
    - **Exercise 10 Steps 2–4:** the first `Forbidden` names `pod-16` and `limits.memory`, and after the new delete, `kubectl get pods -n team-alpha --no-headers | wc -l` prints `0`.
    - **Exercise 03 Steps 1–6:** while paused, `.spec.paused` is `true` and no Pod runs `nginx:1.26-alpine`; after resume, all 3 do.
    - **Exercise 09 Step 4, single node:** `no-toleration` is `Pending` and `tolerating-pod` is `Running` within 60 s.
  - **Round-2 EKS run:**
    - `kubectl get pods -n kube-system -o name | grep -c -E 'kube-apiserver|etcd|kube-scheduler|kube-controller-manager'` prints `0`; on kind it prints `4`.
    - **Exercise 07 Steps 3–4:** `head -1 /data/timestamp.txt` is the same line before and after.
    - **Exercise 10 Step 5:** `kubectl get events --field-selector reason=FailedScheduling | grep -c 'Too many pods'` prints `0`.

### W3: Security-relevant claims

- **Change:**
  - **Exercise 05, `exercises/05-services/README.md:102`:**
    - The annotation asks for an NLB instead of the default Classic Load Balancer.
    - It's internet-facing, in the public subnets tagged `kubernetes.io/role/elb`, and reachable until Step 6.
    - An internal one needs `service.beta.kubernetes.io/aws-load-balancer-internal: "true"`, tested from a Pod.
  - **Exercise 06 Step 1:**
    - Add `kubectl apply view-last-applied secret app-secret`, which prints `DB_PASSWORD` in plain text.
    - Say why: client-side apply saves the file as written, and `kubectl create -f` without `--save-config` doesn't.
    - Rewrite answer 1 to match.
- **Files:** `exercises/05-services/README.md`, `exercises/06-configmaps-and-secrets/README.md`
- **Done when:**
  - `grep -n 'internal NLB instead' exercises/05-services/README.md` and `grep -n 'write-only' exercises/06-configmaps-and-secrets/README.md` print nothing.
  - **On kind:** after exercise 06 Step 1, `kubectl apply view-last-applied secret app-secret | grep -c change-me-before-use` prints `1`.
  - **Round-2 EKS run:** after exercise 05 Step 4, this prints `internet-facing`:

    ```
    aws elbv2 describe-load-balancers --region "$(terraform -chdir=eks output -raw region)" \
      --query "LoadBalancers[?DNSName=='$(kubectl get svc web-app-lb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')'].Scheme" \
      --output text
    ```

### W4: NetworkPolicy text and the DNS rule

- **Change:**
  - **`allow-dns-egress`:** add `to:` with `namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}` and `podSelector: {matchLabels: {k8s-app: kube-dns}}`, keeping UDP and TCP 53. That CoreDNS carries this label on EKS is an *(assumption)*; spike 1 checks it.
  - **Background:**
    - `exercises/11-network-policies/README.md:17` says that only Pods some policy selects are isolated.
    - `:24` says `Ingress` is inferred, and so is `Egress` when there are egress rules.
  - **Answer 2:** enforcement works, and the likely cause is the missing egress allow on the source, or labels or ports that don't match.
  - **Answer 5:** names the CoreDNS Pods and says that policies select Pods, not Services.
  - **`exercises/11-network-policies/README.md:42`:** `--region "$(terraform -chdir=../../eks output -raw region)"`, from part 1 W2.
  - **`exercises/11-network-policies/manifests/deny-all.yaml:4-6`:** the Terraform in `eks/` turns the agent on.
  - **`exercises/11-network-policies/README.md:28`:** Terraform turns the agent on for this cluster (`eks/modules/eks_cluster/addons.tf:12-13`); other clusters need the agent, or Calico or Cilium.
  - **Ship order.** Run spike 1 before the `allow-dns-egress` change lands. If it passes, ship both selectors; if not, ship the `namespaceSelector` alone. The Done when checks whichever form ships.
- **Files:**
  - `exercises/11-network-policies/README.md`
  - `exercises/11-network-policies/manifests/allow-frontend-to-backend.yaml`
  - `exercises/11-network-policies/manifests/deny-all.yaml`
- **Done when:**
  - This prints nothing:

    ```
    git grep -n -e 'not matching any policy is dropped' -e 'must explicitly include' -e 'AWS_REGION:-' -e 'does not enforce NetworkPolicies' -e 'does \*\*not\*\* enforce' -- exercises/11-network-policies
    ```
  - **On kind:**
    - Steps 1–4 verbatim give the results the September spec expects (`docs/specs/2026-09-14-p0-p1-correctness-fixes-2-core-exercises.md:116-120`):
      - Step 2: both `BLOCKED`.
      - Step 3: two succeed and two are `BLOCKED`.
      - Step 4: the lookup resolves.
    - `kubectl exec frontend -- timeout 5 nslookup example.com 8.8.8.8 >/dev/null 2>&1 || echo BLOCKED` prints `BLOCKED`. Before W4 it resolves *(assumption: the shipped rule blocks port 53 to `8.8.8.8`; spike 1 checks it)*.
  - **Round-2 EKS run:** the same checks.

### W5: Other false statements

- **Change:**
  - **Exercise 02:**
    - READY is ready containers.
    - STATUS shows the phase or a container's reason, such as `CrashLoopBackOff`.
    - `Failed` gets the docs' definition: a crash-looping Pod stays `Running`.
  - **Exercise 01:**
    - `get all` is the `all` category; see `kubectl api-resources --categories=all`.
    - Answer 10: the VPC CNI gives each Pod a VPC address, not one from a node Pod CIDR.
  - **Exercise 04, answer 4:** PVCs are retained by default, unless `persistentVolumeClaimRetentionPolicy.whenDeleted: Delete` is set.
  - **Exercise 06, answer 5:** the sync period (1 minute by default) plus the cache delay, which is near zero with the default `Watch`; a `subPath` mount never updates.
  - **Exercise 03, `exercises/03-deployments/README.md:56`:** "All Pods replaced at once, like `Recreate`, except that `Recreate` waits for the old Pods to be removed first."
  - **Exercise 10, `exercises/10-resource-management/README.md:31`:** not Guaranteed, and at least one container sets a CPU or memory request or limit.
  - **Exercise 12 Step 6:** add `kubectl events -A` and `kubectl events -A --types=Warning`.
  - **`README.md:211`:** `kubectl events --all-namespaces --watch`.
  - **`README.md:173`:** keep the bash line, and add `setopt PROMPT_SUBST` with `export PROMPT='[%n@%m %1~ $(kubectl config view --minify --output "jsonpath={.contexts[0].context.namespace}" 2>/dev/null)]%# '` for zsh, in a separate fenced block labelled zsh after the bash one, each line starting at column 0.
- **Files:**
  - `README.md`
  - `exercises/01-kubernetes-architecture/README.md`
  - `exercises/02-pods-and-containers/README.md`
  - `exercises/03-deployments/README.md`
  - `exercises/04-daemonsets-and-statefulsets/README.md`
  - `exercises/06-configmaps-and-secrets/README.md`
  - `exercises/10-resource-management/README.md`
  - `exercises/12-troubleshooting/README.md`
- **Done when:**
  - This prints nothing:

    ```
    git grep -n -e 'running containers>' -e 'exited non-zero or was killed' -e 'every object in the cluster' -e "node's Pod CIDR" -e 'delete them manually' -e 'cache TTL' -e 'if surge > 0' -e "lastTimestamp' -w" -- README.md exercises
    ```
  - `grep -c 'kubectl events' exercises/12-troubleshooting/README.md` prints at least `3`: the objective at `exercises/12-troubleshooting/README.md:8` and the two new commands.
  - Piped to `grep -E '^\[.+@.+\]% ?$'`, this prints its one line (the prompt ends in a space), and piped to `grep -c '%[nm]'` it prints `0`. The namespace part may be empty:

    ```
    zsh -f -c "$(grep -E '^(setopt PROMPT_SUBST|export PROMPT=)' README.md)"'; print -rP -- "$PROMPT"'
    ```
  - **On kind:**
    - During exercise 02 Step 6, `kubectl get pod multi-container-pod -o jsonpath='{.status.phase}'` prints `Running` while STATUS shows `CrashLoopBackOff`.
    - `kubectl api-resources --categories=all -o name | grep -c -E '^(configmaps|secrets)$'` prints `0`.

## Effort

| Item | Estimate | Depends on |
|---|---|---|
| W1 | 2 h | — |
| W2 | 2 h | — |
| W3 | 45 min | part 1 W2, for the EKS check |
| W4 | 1.5 h plus spike 1 | part 1 W2 |
| W5 | 1.5 h | — |

Estimated from reading the code, so trust the ordering more than the numbers. The kind checks are free; the EKS checks share the round-2 EKS run.

## Spike questions

1. Does the VPC CNI's policy agent let DNS sent to the kube-dns ClusterIP through a `to` rule that selects the CoreDNS Pods, and do those Pods carry `k8s-app: kube-dns`?
   - Experiment: in the round-2 EKS run, run exercise 11 Steps 2–4 with W4's rule, plus `kubectl -n kube-system get pods -l k8s-app=kube-dns`.
   - If the lookup fails, fall back to the `namespaceSelector` alone.
2. Can a Pod reach a node's InternalIP on NodePort 30080 on EKS?
   - Experiment: in the round-2 EKS run, run exercise 05 Step 3 against each node's InternalIP.

## Risks and rollback

- **DNS.** Until spike 1 runs, W4's narrower rule might break lookups on EKS; the fallback is one selector.
- **Exercise 09's placeholder.** The `TAINTED_NODE` placeholder makes a plain `kubectl apply` of the manifest stay `Pending`. The README always pipes through `sed`, and the clean-up deletes by name.
- **Rollback.** Every item is docs or manifests, so revert it per work item.

## Open questions

- None.
