---
title: Correctness fixes, round 2, part 4 — GPU track
created: 2026-10-09
status: draft # draft | reviewed | in-progress | done | superseded
research: ~/notes/research/2026-10-09-kubernetes-dojo-critical-analysis.md
idea: none
read-at: 5119a98
cite-repo: none
---

# Correctness fixes, round 2, part 4 — GPU track

## Goal

Every GPU exercise runs as written on part 1's cluster (`docs/specs/2026-10-09-correctness-fixes-round-2-1-platform.md`, a prerequisite):
- each exercise brings up its GPU node and scales it away afterwards;
- exercise 05 shows real metrics;
- exercise 06 uses part 1's opt-in EFS;
- nothing in the track is false.

The research note (`research:` above) explains why.

## Decision

This spec takes option A from the research's Recommendation: fix the GPU track's P0/P1 defects and every false statement in it now, run the result on EKS before any part merges, then write the kind and CI spec that the 2026-09-14 specs deferred.

Rejected:
- **B (CI and kind first)** leaves the data-loss and cost defects in place while CI is built, and kind can't run the EKS-only steps.
- **Doing nothing** leaves every learner meeting them.

Choices made at interview (2026-10-09):
- **Scope:** the P0/P1 defects, plus every lower-severity item that is a failing step or a false statement. Version currency, drills, the kind move, CI and repo tidying go to later specs.
- **EFS:** becomes an opt-in Terraform setting.
- **Teardown:** gets a pre-destroy script.
- **GPU nodes:** each GPU exercise scales its own nodes up at the start and down at the end.

## Background

Read at `5119a98` on 2026-10-09. Square-bracket numbers are sources in the research note. Sources the note doesn't list are given by URL, with the date they were read.

### Region and nodes

**Region.**
- `AWS_REGION=eu-west-2` is hard-coded in `gpu-ml/README.md:35`, `gpu-ml/exercises/01-gpu-node-setup/README.md:44`, `gpu-ml/exercises/02-gpu-scheduling/README.md:51` and `gpu-ml/exercises/06-storage-for-ml/README.md:50`.
- The Prerequisites of 03, 04, 05 and 07 set no region at all (`gpu-ml/exercises/03-distributed-training/README.md:47-54`, `gpu-ml/exercises/04-model-serving/README.md:51-57`, `gpu-ml/exercises/05-gpu-monitoring/README.md:49-61`, `gpu-ml/exercises/07-cost-and-efficiency/README.md:65-71`).
- `eks/outputs.tf:1-35` has no region output; part 1 W2 adds one.

**Node lifecycle.**
- The `gpu` group starts at 0 nodes, with a maximum of 2, and Terraform ignores later scaling (`eks/variables.tf:132-133`, `eks/modules/node_group/node_group.tf:87-89`).
- Exercise 03's clean-up scales it to 0 (`gpu-ml/exercises/03-distributed-training/README.md:200-204`). Exercises 04, 05 and 07 need a node but never scale up (`gpu-ml/exercises/04-model-serving/README.md:54`, `gpu-ml/exercises/05-gpu-monitoring/README.md:94-95`, `gpu-ml/exercises/07-cost-and-efficiency/README.md:68`), and 07, the last, never scales down (`gpu-ml/exercises/07-cost-and-efficiency/README.md:188-205`), at $0.615/h (`gpu-ml/README.md:63`).
- The waits are unbounded loops (`gpu-ml/exercises/01-gpu-node-setup/README.md:72-74`, `gpu-ml/exercises/03-distributed-training/README.md:117-119`) that spin forever when the GPU quota blocks a launch.
- Exercise 06's pods request no GPU (`gpu-ml/exercises/06-storage-for-ml/manifests/dataset-writer-pod.yaml:5-41`, `gpu-ml/exercises/06-storage-for-ml/manifests/dataset-reader-pod.yaml:5-32`).

### Exercise 05

- **Unpinned stack.** `gpu-ml/exercises/05-gpu-monitoring/README.md:58-60` installs kube-prometheus-stack with no version. The pin is 92.2.0, whose chart has `appVersion: v0.94.1` ([Chart.yaml#L31-L33](https://github.com/prometheus-community/helm-charts/blob/kube-prometheus-stack-92.2.0/charts/kube-prometheus-stack/Chart.yaml#L31-L33)); that it was the newest on 2026-10-09 is *(unverified)*. Rendered as `kube-prometheus`, it selects ServiceMonitors labelled `release: kube-prometheus`, and its Prometheus Service matches `:115`.
- **Skipped ServiceMonitor.** Step 1 sets `serviceMonitor.interval=15s` (`gpu-ml/exercises/05-gpu-monitoring/README.md:82`), but `helm show values gpu-helm-charts/dcgm-exporter --version 4.8.3` gives `scrapeTimeout: 25s` ([values.yaml#L164-L168](https://github.com/NVIDIA/dcgm-exporter/blob/4.6.0-4.8.3/deployment/values.yaml#L164-L168)). The operator skips a ServiceMonitor whose timeout exceeds its interval ([promcfg.go#L989](https://github.com/prometheus-operator/prometheus-operator/blob/c060f78f0437f4ec418786d1b4c45754da220d52/pkg/prometheus/promcfg.go#L989) [16]). The same values offer `extraEnv` ([#L221](https://github.com/NVIDIA/dcgm-exporter/blob/4.6.0-4.8.3/deployment/values.yaml#L221)), and the Service port is named `metrics`, on 9400.
- **No `curl`.** Steps 2 and 5 run `curl` in the exporter pod (`gpu-ml/exercises/05-gpu-monitoring/README.md:98`, `:165-166`), whose image has none [17] *(unverified)*.
- **Hidden utilisation.** The exporter collects every 30 s by default ([app.go#L179-L183](https://github.com/NVIDIA/dcgm-exporter/blob/4.6.0-4.8.3/pkg/cmd/app.go#L179-L183) [27]). Step 5's load (`gpu-ml/exercises/05-gpu-monitoring/README.md:161`) is ten steps on a 64×10 batch (`gpu-ml/exercises/03-distributed-training/manifests/single-gpu-job.yaml:26-35`), too short to register *(assumption)*.
- **Answer 4's join can't match.** It joins `kube_node_labels` on `instance` (`gpu-ml/exercises/05-gpu-monitoring/README.md:202`).
  - kube-state-metrics exports node labels only through `--metric-labels-allowlist`, as `label_*` ([CLI arguments](https://github.com/kubernetes/kube-state-metrics/blob/main/docs/developer/cli-arguments.md) [36]) *(unverified)*.
  - The exporter's `Hostname` label is the node name ([hostname.go#L98-L101](https://github.com/NVIDIA/dcgm-exporter/blob/4.6.0-4.8.3/internal/pkg/hostname/hostname.go#L98-L101), read 2026-10-09).
  - Rendering 92.2.0 with `--set 'kube-state-metrics.metricLabelsAllowlist[0]=nodes=[team]'` adds that flag.

### Exercise 06

- **No credentials.** The EFS driver is installed with Helm and no IAM role (`gpu-ml/exercises/06-storage-for-ml/README.md:55-59`), but it needs one ([EFS CSI driver](https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html) [18]) *(unverified)*. Pods can't reach IMDS (`eks/modules/node_group/node_group.tf:10-14`), and the node role has no EFS policy (`eks/modules/node_group/iam.tf:14-27`).
- **No file system.** The exercise looks one up by a `cluster` tag (`gpu-ml/exercises/06-storage-for-ml/README.md:61-65`), but nothing creates it. Part 1 W5 adds the file system, the add-on with its role, and `output "efs_file_system_id"`, behind `enable_efs`.
- **Clean-up leaks.**
  - `gpu-ml/exercises/06-storage-for-ml/README.md:74` edits a tracked file with `sed -i`, a form BSD sed rejects *(assumption: macOS sed(1) takes `-i extension`)*.
  - `gpu-ml/exercises/06-storage-for-ml/manifests/efs-storageclass.yaml:13` is `Retain`, so the clean-up (`gpu-ml/exercises/06-storage-for-ml/README.md:173-179`) leaves the Released PV, its access point and the file system.
- **No NVMe.** `gpu-ml/exercises/06-storage-for-ml/README.md:24`, `gpu-ml/README.md:123` and `README.md:147` promise NVMe scratch. But the launch template sets only a gp3 root volume and no user data (`eks/modules/node_group/node_group.tf:6-46`), so nothing configures the instance store.

### Exercises 03 and 04

- **Impossible loss.** The single-GPU Job fits random targets to random inputs (`gpu-ml/exercises/03-distributed-training/manifests/single-gpu-job.yaml:26-27`), so `loss: 0.0312` (`gpu-ml/exercises/03-distributed-training/README.md:79`) can't happen. Re-running the loop in pure Python over 300 seeds, it never ended below 0.67. With `y = x @ true_w`, `lr=0.1` and 30 epochs, the first loss had a median of 9.0 and the last never exceeded 0.036 *(assumption: an unrecorded local simulation)*.
- **Device string.** `torch.device("cuda")` (`gpu-ml/exercises/04-model-serving/manifests/model-server-deployment.yaml:31`) prints `cuda`, not `cuda:0` (`gpu-ml/exercises/04-model-serving/README.md:114`) *(assumption)*.
- **Truncated logs.** With a selector, `kubectl logs` prints 10 lines per pod unless given `--tail=-1` (`kubectl logs --help`, 1.37), and Step 4 uses one (`gpu-ml/exercises/03-distributed-training/README.md:138`, `:141`). Answer 5 (`:225`) suggests `--previous` for completed pods, which only reads a restarted container.
- **Exercise 04's server.** It is described as FastAPI (`gpu-ml/exercises/04-model-serving/README.md:63`) but is `http.server` (`gpu-ml/exercises/04-model-serving/manifests/model-server-deployment.yaml:29`). It runs a 5→64→1 model (`:35-40`), and each replica requests a whole GPU (`:76-81`).
- **Exercise 04's load test.** Step 5's body ends `]}}` (`gpu-ml/exercises/04-model-serving/README.md:146`), which `json.loads` rejects with `Extra data`. It needs `shuf`, which macOS lacks, and `dmon` runs only after the loop (`:153`). Answer 5 (`:185`) ignores that a second replica stays Pending on one g4dn.xlarge, and that a port-forward reaches only one pod.

### Other false claims

- **Whole GPUs.** Exercise 02 says the scheduler enforces requests equal to limits and that time-slicing allows fractions (`gpu-ml/exercises/02-gpu-scheduling/README.md:20-24`). Its answer 1 treats a 0/1 pair as no request (`gpu-ml/exercises/02-gpu-scheduling/README.md:170`), and `gpu-ml/README.md:144` repeats the time-slicing exception. The API server rejects both cases: every extended resource is an integer ([validation.go#L8222-L8230](https://github.com/kubernetes/kubernetes/blob/v1.36.5/pkg/apis/core/validation/validation.go#L8222-L8230), [helpers.go#L293-L294](https://github.com/kubernetes/kubernetes/blob/v1.36.5/pkg/apis/core/helper/helpers.go#L293-L294) [11]), and one that can't be overcommitted must request exactly its limit ([validation.go#L7975-L7977](https://github.com/kubernetes/kubernetes/blob/v1.36.5/pkg/apis/core/validation/validation.go#L7975-L7977), [helpers.go#L208-L211](https://github.com/kubernetes/kubernetes/blob/v1.36.5/pkg/apis/core/helper/helpers.go#L208-L211), read 2026-10-09).
- **Exclusivity** (`gpu-ml/exercises/01-gpu-node-setup/README.md:25`, `gpu-ml/exercises/02-gpu-scheduling/README.md:10`, `gpu-ml/exercises/02-gpu-scheduling/README.md:28`) holds only among pods that request a GPU. A container that requests none sees every GPU ([device plugin README](https://github.com/NVIDIA/k8s-device-plugin) [26]) *(unverified)*.
- **Time-slicing** gives each process an equal share of time, and if one workload crashes they all do ([device plugin README](https://github.com/NVIDIA/k8s-device-plugin) [26]) *(unverified)*. Exercise 07's tradeoff (`gpu-ml/exercises/07-cost-and-efficiency/README.md:30`), answer 1 (`:221`) and answer 6 (`:226`) omit or deny this.
- **MIG** (`gpu-ml/exercises/07-cost-and-efficiency/README.md:34-41`). The table is wrong in four cells and limits MIG to A100 and H100. NVIDIA's limits are 3× 2g.10gb and 2× 3g.20gb on A100 40 GB, and 3× 2g.20gb and 1× 4g.40gb on H100 80 GB, and A30, H200 and B200 also support MIG ([supported MIG profiles](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/supported-mig-profiles.html), read 2026-10-09; research [34]) *(unverified)*.
- **Spot** (`gpu-ml/exercises/07-cost-and-efficiency/README.md:45-49`).
  - `spot_interruption_handler` isn't a real setting.
  - Managed node groups drain Spot nodes through Capacity Rebalancing ([managed node groups](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html) [7]) *(unverified)*, so they don't need the termination handler ([NTH README](https://github.com/aws/aws-node-termination-handler) [25]) *(unverified)*. Step 4 installs it anyway (`gpu-ml/exercises/07-cost-and-efficiency/README.md:141-155`).
  - The "Indexed" line (`gpu-ml/exercises/07-cost-and-efficiency/README.md:49`) contradicts "one worker's failure stops the whole job" (`gpu-ml/exercises/03-distributed-training/README.md:181`).
  - Step 3's `spotAllocationStrategy` (`gpu-ml/exercises/07-cost-and-efficiency/README.md:136`) isn't returned by `describe-nodegroup` *(unverified)*.
- **Quota.** `limits.nvidia.com/gpu` (`gpu-ml/exercises/07-cost-and-efficiency/manifests/gpu-resource-quota.yaml:9`) is ignored for extended resources ([resource quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/) [12]) *(unverified)*.
- **Exercise 01.**
  - Its STATUS column (`gpu-ml/exercises/01-gpu-node-setup/README.md:60`) prints `.status.conditions[-1].type`, which is `Ready` even on a NotReady Node fixture (`kubectl annotate --local -f <fixture> probe=x -o jsonpath=...`).
  - Step 4 waits for Ready on a run-to-completion pod (`gpu-ml/exercises/01-gpu-node-setup/README.md:140`).
  - It expects driver 535 (`gpu-ml/exercises/01-gpu-node-setup/README.md:148`), where current GPUs need 580 ([accelerated AMIs](https://docs.aws.amazon.com/eks/latest/userguide/ml-eks-optimized-ami.html) [30]) *(unverified)*.

## Non-goals

- DRA, the GPU Operator, Karpenter, EKS Auto Mode, and the instance-family table (`gpu-ml/README.md:103-110`).
- Multi-GPU nodes, hands-on MIG, and switching the group to Spot.
- Image pins, and exercise 03's DDP sample numbers.
- Part 1's Terraform, parts 2 and 3, kind and CI.

## Design

**`gpu-ml/gpu-nodes.sh` (new)**
- **Inputs.** It reads the cluster name and region with `terraform -chdir="$(git rev-parse --show-toplevel)/eks" output -raw <name>`.
- **Calls.** It reads the group's size with `aws eks describe-nodegroup --region <region> … --query nodegroup.scalingConfig.desiredSize`, sets it with `aws eks update-nodegroup-config --region <region> … --scaling-config desiredSize=N`, and counts nodes with `kubectl get nodes -l workload-type=gpu`.
- **Setup.** It's executable and listed in `gpu-ml/README.md`'s prerequisites. It's called as `../../gpu-nodes.sh` from the exercise directory, which the exercises' `manifests/` paths already assume.
- `up [N]` (default 1):
  1. sets the `gpu` group's desired size to exactly N, lowering it too, so a skipped `down` can't leave extra nodes;
  2. polls every 15 s until exactly N `workload-type=gpu` nodes are Ready, for at most `GPU_WAIT_SECONDS` (default 900);
  3. on timeout, points at the quota check in `gpu-ml/README.md` and exits 1.
- `down` sets the desired size to 0.

**Who calls it.**
- Exercises 01–05 and 07 run `../../gpu-nodes.sh up` in Prerequisites; exercise 03 runs `up 2`.
- Their clean-ups end with `../../gpu-nodes.sh down`, which can be skipped when going straight on to the next exercise. Exercise 05 always runs it, because 06 needs no GPU, and so does 07, because it's last.
- Exercise 06 runs neither.

## Work items

### W1: GPU nodes and region in every exercise

- **Change:**
  - Add the helper and its calls, as Design says. It replaces the scale-ups in exercise 01 (`gpu-ml/exercises/01-gpu-node-setup/README.md:63-75`) and exercise 03 (`gpu-ml/exercises/03-distributed-training/README.md:108-121`); keep 03's cost sentence.
  - Replace the four hard-coded region lines, and add the same line to 03, 04, 05 and 07: `export AWS_REGION=$(terraform -chdir="$(git rev-parse --show-toplevel)/eks" output -raw region)`.
  - Point `gpu-ml/README.md:84-99` at the helper.
- **Files:** `gpu-ml/gpu-nodes.sh` (new), `gpu-ml/README.md`, all seven exercise READMEs.
- **Done when:**
  - `bash -n gpu-ml/gpu-nodes.sh` exits 0.
  - `git grep -n 'AWS_REGION=eu-west-2\|until \[' -- 'gpu-ml/*.md'` prints nothing.
  - `git grep -l 'output -raw region' -- 'gpu-ml/*.md' | wc -l` prints `8`.
  - `git grep -l 'gpu-nodes.sh up' -- gpu-ml/exercises` lists 01–05 and 07, but not 06.
  - With stubs first on `PATH` (`terraform` prints fixed outputs, `aws` logs its arguments and prints `0`, and `kubectl` prints no nodes), `GPU_WAIT_SECONDS=30 gpu-ml/gpu-nodes.sh up; echo "exit=$?"` prints the quota pointer and `exit=1` within 60 s.
  - Round-2 EKS run:
    - after 03's clean-up, 04's Prerequisites leave one Ready GPU node;
    - after 07's clean-up, `aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name gpu --query nodegroup.scalingConfig.desiredSize` prints `0`.

### W2: Exercise 05 shows real metrics

- **Change:**
  - Prerequisites (`gpu-ml/exercises/05-gpu-monitoring/README.md:52-60`):
    - Drop the "If not present" check (`:52-55`), so `helm upgrade --install kube-prometheus` always runs and brings an existing `kube-prometheus` release to the pin.
    - Add `--version 92.2.0` and `--set 'kube-state-metrics.metricLabelsAllowlist[0]=nodes=[team]'`.
    - A stack installed under another release name is out of scope: say to remove it first.
  - Step 1 (`:74-83`): add `--set serviceMonitor.scrapeTimeout=10s`, `--set 'extraEnv[0].name=DCGM_EXPORTER_INTERVAL'` and `--set-string 'extraEnv[0].value=5000'`.
  - Step 2 starts `kubectl -n monitoring port-forward svc/dcgm-exporter 9400:9400 &` and saves `DCGM_PF_PID=$!`, since Step 3 already uses `PF_PID` (`gpu-ml/exercises/05-gpu-monitoring/README.md:116`, `:129`). Each `kubectl exec … curl` (`:98`, `:165-166`) becomes `curl -s http://localhost:9400/metrics`, and Step 5 ends with `kill $DCGM_PF_PID`. With exactly one GPU node (W1's `up`) and the exporter's `nodeSelector` (`:80`), the Service has one pod behind it. Delete the now-unused `DCGM_POD=` assignment (`gpu-ml/exercises/05-gpu-monitoring/README.md:94-95`).
  - Step 5 (`:161`) applies a new `manifests/gpu-load-job.yaml`, a Job named `gpu-load`, and its clean-up (`:172`) deletes `job/gpu-load` instead of `single-gpu-training`. The Job requests one GPU, with exercise 03's toleration and `nodeSelector`. It runs `pytorch/pytorch:2.2.0-cuda12.1-cudnn8-runtime` and multiplies `a = torch.randn(4096, 4096, device="cuda")` by itself for 180 s, then calls `torch.cuda.synchronize()`. The step polls with `for i in $(seq 18); do …; sleep 10; done` (3 minutes; not an `until` loop, which W1's grep forbids), and warns that the first polls may read 0 while the image pulls.
  - Answer 4 (`:202`): set `GPU_NODE=$(kubectl get nodes -l workload-type=gpu -o jsonpath='{.items[0].metadata.name}')`, since exercise 05 never defines it, and run `kubectl label node "$GPU_NODE" team=nlp`. Then `sum by (label_team) (DCGM_FI_DEV_POWER_USAGE * on (Hostname) group_left (label_team) label_replace(kube_node_labels, "Hostname", "$1", "node", "(.*)"))`.
- **Files:** `gpu-ml/exercises/05-gpu-monitoring/README.md`, `gpu-ml/exercises/05-gpu-monitoring/manifests/gpu-load-job.yaml` (new)
- **Done when:**
  - `grep -n 'exec -n monitoring' gpu-ml/exercises/05-gpu-monitoring/README.md` prints nothing.
  - Step 1's command, run as `helm template dcgm-exporter` instead of `helm upgrade --install dcgm-exporter`, renders the ServiceMonitor with `interval: "15s"` and `scrapeTimeout: "10s"`, and `DCGM_EXPORTER_INTERVAL` set to `"5000"`.
  - `helm template kube-prometheus prometheus-community/kube-prometheus-stack --version 92.2.0 --set 'kube-state-metrics.metricLabelsAllowlist[0]=nodes=[team]' | grep -c -- '--metric-labels-allowlist=nodes=\[team\]'` prints `1`.
  - Round-2 EKS run: Step 2 prints a `DCGM_FI_DEV_GPU_UTIL{` line; Step 3's first query returns a non-empty `.data.result` within 2 minutes of Step 1; a Step 5 poll prints 50 or more; and answer 4's query returns one series.

### W3: Exercise 06 on the opt-in EFS

- **Change:**
  - Prerequisites (`gpu-ml/exercises/06-storage-for-ml/README.md:48-66`):
    - say that no GPU node is needed;
    - set `enable_efs = true` in `eks/terraform.tfvars` and apply;
    - run `kubectl -n kube-system rollout status deployment/efs-csi-controller --timeout=300s`;
    - set `EFS_ID=$(terraform -chdir="$(git rev-parse --show-toplevel)/eks" output -raw efs_file_system_id)`;
    - delete the Helm install and the tag lookup.
  - Step 1 (`:74`): `sed "s/EFS_ID_PLACEHOLDER/${EFS_ID}/" manifests/efs-storageclass.yaml | kubectl apply -f -`.
  - Set `reclaimPolicy: Delete` in `gpu-ml/exercises/06-storage-for-ml/manifests/efs-storageclass.yaml:13`, so that deleting the PVC also removes its PV and access point *(assumption; spike question 1)*. A class's `reclaimPolicy` can't change in place, so the Prerequisites run `kubectl delete storageclass efs-ml --ignore-not-found` before Step 1. The name is at `gpu-ml/exercises/06-storage-for-ml/manifests/efs-storageclass.yaml:4`, and the clean-up deletes the class too.
  - Clean-up (`gpu-ml/exercises/06-storage-for-ml/README.md:173-179`): after the PVC delete:
    1. Wait up to 5 minutes with `for i in $(seq 60); do [ -z "$(kubectl get pv -o jsonpath='{.items[?(@.spec.claimRef.name=="shared-dataset")].metadata.name}')" ] && break; sleep 5; done`.
    2. If `aws efs describe-access-points --file-system-id "$EFS_ID" --query 'AccessPoints[].AccessPointId' --output text` still lists any, delete each with `aws efs delete-access-point --access-point-id <id>`.
    3. Set `enable_efs = false` and apply.
  - Answer 5 (`:198`): add a driver without IAM permissions as a cause.
  - `:24` becomes "`emptyDir` (node-local disk)". Drop "NVMe scratch" from `gpu-ml/README.md:123` and `README.md:147`.
- **Files:** `gpu-ml/exercises/06-storage-for-ml/README.md`, `gpu-ml/exercises/06-storage-for-ml/manifests/efs-storageclass.yaml`, `gpu-ml/README.md`, `README.md`
- **Done when:**
  - `git grep -n 'helm upgrade --install aws-efs-csi-driver\|sed -i\|Key==.cluster.\|NVMe scratch\|node NVMe' -- gpu-ml README.md` prints nothing.
  - Both `grep -n efs_file_system_id gpu-ml/exercises/06-storage-for-ml/README.md` and `grep -n 'reclaimPolicy: Delete' gpu-ml/exercises/06-storage-for-ml/manifests/efs-storageclass.yaml` match.
  - `sed "s/EFS_ID_PLACEHOLDER/fs-0123456789abcdef0/" gpu-ml/exercises/06-storage-for-ml/manifests/efs-storageclass.yaml | grep -c 'fileSystemId: fs-0123456789abcdef0'` prints `1`.
  - Round-2 EKS run:
    - the PVC is `Bound` within 60 s of Step 1, and `kubectl logs dataset-reader | grep -c 'RWX mount confirmed'` prints `1`;
    - after the PVC delete, `aws efs describe-access-points --file-system-id "$EFS_ID" --query 'length(AccessPoints)'` prints `0`;
    - after `enable_efs = false`, `aws efs describe-file-systems --query "length(FileSystems[?FileSystemId=='$EFS_ID'])"` prints `0`.

### W4: Exercises 03 and 04 match what runs

- **Change:**
  - **Single-GPU Job** (`gpu-ml/exercises/03-distributed-training/manifests/single-gpu-job.yaml:26-35`): `true_w = torch.randn(10, 1, device=device)`, `y = x @ true_w`, `lr=0.1`, and 30 epochs printed as `Epoch {epoch}/30`. Its expected output (`gpu-ml/exercises/03-distributed-training/README.md:76-81`) becomes a loss falling from about 9 to below 0.05, ending with `device: cuda`.
  - **Exercise 03 logs.** Step 4 (`gpu-ml/exercises/03-distributed-training/README.md:138`, `:141`) adds `--tail=-1`. Answer 5 (`:225`) becomes `kubectl logs -l job-name=<name> --prefix --tail=-1`.
  - **Exercise 04 text.** `gpu-ml/exercises/04-model-serving/README.md:63` becomes "a small Python `http.server` server". The expected output at `:114` becomes `"device": "cuda"`, with `latency_ms` in the tens.
  - **Exercise 04 server** (`gpu-ml/exercises/04-model-serving/manifests/model-server-deployment.yaml:55-58`): at load, set `w = torch.randn(2048, 2048, device=device)`. In the timed block, after the model call, run `w @ w` `WORK_MATMULS` times (default 20), then `torch.cuda.synchronize()` on CUDA.
  - **Exercise 04 Step 5** (`gpu-ml/exercises/04-model-serving/README.md:137-154`):
    - start `kubectl exec "$POD" -- nvidia-smi dmon -s u -d 1 -c 15 &` before the loop;
    - send 100 requests with five `$((RANDOM % 10 + 1))` values in `{"input": [...]}`, through `curl -s -o /dev/null -w '%{http_code} '`;
    - then `wait` for `dmon` to finish.
  - **Answer 5** (`:185`): the second replica stays Pending on one g4dn.xlarge, and a port-forward sends all traffic to one pod.
- **Files:** `gpu-ml/exercises/03-distributed-training/manifests/single-gpu-job.yaml`, `gpu-ml/exercises/03-distributed-training/README.md`, `gpu-ml/exercises/04-model-serving/manifests/model-server-deployment.yaml`, `gpu-ml/exercises/04-model-serving/README.md`
- **Done when:**
  - `grep -n 'x @ true_w' gpu-ml/exercises/03-distributed-training/manifests/single-gpu-job.yaml` matches.
  - `git grep -n 'loss: 0.0312\|"device": "cuda:0"\|FastAPI\|shuf \|--previous' -- gpu-ml` prints nothing.
  - `grep -c -- '--tail=-1' gpu-ml/exercises/03-distributed-training/README.md` prints `3` or more.
  - Step 5's body, built as the README builds it and piped to `python3 -c 'import json,sys; print(len(json.load(sys.stdin)["input"]))'`, prints `5`. Today's body fails with `Extra data`.
  - Round-2 EKS run:
    - the Job's `Epoch 30/30` line shows a loss below 0.05 and `device: cuda`;
    - Step 5 prints 100 `200` codes;
    - `dmon`'s `sm` column reaches 50.

### W5: Correct the remaining GPU claims

- **Change:** correct each claim that Background lists under "Other false claims".
  - **Exercise 02.** `gpu-ml/exercises/02-gpu-scheduling/README.md:20-24` becomes: the API server rejects GPU requests that aren't whole numbers or that differ from their limit, and time-slicing adds whole units. Answer 1 (`:170`) and `gpu-ml/README.md:144` become: the pod is rejected with `must be equal to nvidia.com/gpu limit of 1`.
  - **Exclusivity** (`gpu-ml/exercises/01-gpu-node-setup/README.md:25`, `gpu-ml/exercises/02-gpu-scheduling/README.md:10`, `gpu-ml/exercises/02-gpu-scheduling/README.md:28`) becomes: exclusive among pods that request a GPU. A container that requests none sees every GPU, which is one reason for the taint.
  - **Exercise 07** (`gpu-ml/exercises/07-cost-and-efficiency/README.md:34-41` onwards):
    - **MIG** gets NVIDIA's counts, and its GPU list becomes "A100, A30, H100, H200 and B200, among others".
    - **Spot.** The `spot_interruption_handler` line (`:48`) becomes the managed-node-group behaviour. The Indexed line (`:49`) becomes "an Indexed Job restarts only the failed pod, but DDP still stalls at its rendezvous, so checkpoint". Step 3 (`:136`) drops `spotAllocationStrategy`, and the clean-up drops its NTH line (`:194`). Question and answer 4 (`:214`, `:224`) drop the termination handler: EKS drains a managed node group's Spot node within the 2-minute interruption notice *(unverified)*.
    - **Step 4** (`:141-155`) becomes `aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name gpu --query 'nodegroup.resources.autoScalingGroups[0].name' --output text)" --query 'AutoScalingGroups[0].CapacityRebalance'`, noting that a `SPOT` group reports `true` *(assumption)*.
    - **Time-slicing.** The tradeoff (`:30`) gains the shared fault domain. Answer 1 (`:221`) becomes: one pod can exhaust vRAM so the others' allocations fail, and a crash takes them all down. Answer 6 (`:226`) becomes: time is shared equally, so the light pods slow down but aren't starved.
    - **Quota.** Delete `limits.nvidia.com/gpu` from `:58` and from `gpu-ml/exercises/07-cost-and-efficiency/manifests/gpu-resource-quota.yaml:9`.
  - **Exercise 01.** The column at `gpu-ml/exercises/01-gpu-node-setup/README.md:60` becomes `READY:.status.conditions[?(@.type=="Ready")].status`. Step 4 (`:140`) runs `kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/nvidia-smi --timeout=300s`. The expected driver (`:148`) becomes `580.x`.
- **Files:** `gpu-ml/README.md`, the READMEs of exercises 01, 02 and 07, `gpu-ml/exercises/07-cost-and-efficiency/manifests/gpu-resource-quota.yaml`
- **Done when:**
  - `git grep -n 'unless GPU time-slicing\|not natively supported without time-slicing\|spot_interruption_handler\|spotAllocationStrategy\|aws-node-termination-handler\|does the Node Termination Handler\|Node Termination Handler must\|^ *limits.nvidia.com/gpu:\|conditions\[-1\]\|does not enforce equal sharing\|535' -- gpu-ml` prints nothing.
  - Both `grep -n '3× 2g.10gb, 2× 3g.20gb' gpu-ml/exercises/07-cost-and-efficiency/README.md` and `grep -n '3× 2g.20gb, 1× 4g.40gb' gpu-ml/exercises/07-cost-and-efficiency/README.md` match.
  - On a Node fixture whose Ready condition is False, `kubectl annotate --local -f <fixture> probe=x -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'` prints `False`.
  - On kind or in the round-2 EKS run, `kubectl apply --dry-run=server -f -` of `gpu-ml/exercises/02-gpu-scheduling/manifests/gpu-pod.yaml`:
    - fails with `must be an integer` when the request and limit are `0.5`;
    - fails with `must be equal to nvidia.com/gpu limit of 1` when the request alone is `0`.
  - Round-2 EKS run: the new Step 4 prints `false` for the `ON_DEMAND` group *(assumption; spike question 2)*.

## Effort

| Item | Estimate | Depends on |
|---|---|---|
| W1 | 2–3 h | part 1 W2 (`region` output) |
| W2 | 2 h | W1 |
| W3 | 1.5 h | part 1 W5 (`enable_efs`, `efs_file_system_id`) |
| W4 | 1.5 h | W1 |
| W5 | 2 h | W1 |

Estimates come from reading the files, so trust their order more than the hours. The EKS checks ride on part 1's round-2 EKS run, with one GPU node, or two for exercise 03.

## Spike questions

1. Does the EFS CSI driver delete a dynamically provisioned access point when its PVC is deleted under `reclaimPolicy: Delete`? Experiment: W3's access-point count in the round-2 EKS run. If it isn't 0, W3's clean-up deletes the leftovers by hand. The automatic path needs the driver's role from part 1 W5 to allow `DeleteAccessPoint` *(assumption)*.
2. What `CapacityRebalance` value does an `ON_DEMAND` managed node group's Auto Scaling group report? Experiment: W5's new Step 4 in the round-2 EKS run.
3. Do 20 multiplications of a 2048×2048 matrix per request push `dmon`'s `sm` to 50 on a T4, while keeping `latency_ms` under 200? Experiment: W4's Step 5 in the round-2 EKS run; tune `WORK_MATMULS` if not.

## Risks and rollback

- **Time.** Each GPU exercise waits about 3 minutes for a node (`gpu-ml/exercises/01-gpu-node-setup/README.md:70`) and pulls its images again. That's the price of never leaving one billing.
- **Ordering.** W1 and W3 need part 1's `region` and `efs_file_system_id` outputs, so this part can't land first.
- **Rollback.** Everything here is docs, manifests and one new script. Revert per item.

## Open questions

- None.
