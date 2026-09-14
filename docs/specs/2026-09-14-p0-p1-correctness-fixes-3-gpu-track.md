---
title: P0/P1 correctness fixes, part 3 — GPU track
created: 2026-09-14
status: draft # draft | reviewed | in-progress | done | superseded
research: ~/notes/research/2026-09-14-kubernetes-dojo-critical-review.md
idea: none
read-at: f086d6b
cite-repo: none
---

# P0/P1 correctness fixes, part 3 — GPU track

## Goal

After this part, the GPU exercises work on the GPU node group that part 1 creates (`2026-09-14-p0-p1-correctness-fixes-1-platform.md`, W3, a prerequisite):
- the device plugin is found by its real name and labels;
- time-slicing is configured the way the chart supports;
- the DCGM queries use metric names the exporter emits;
- exercise 03 does real PyTorch DDP.

The research note `~/notes/research/2026-09-14-kubernetes-dojo-critical-review.md` explains why.

## Decision

This spec takes option B, the research's Recommendation, and covers the GPU P1 rows of Recommendation step 2. At interview (2026-09-14), the choice for exercise 03 was "make it real DDP" rather than "rename it". Real DDP keeps the distributed-training exercise that the overview tables promise (`README.md:20`, `README.md:144`, and `gpu-ml/README.md:93`, the `| 03 | Distributed training |` row), and it can be tested on CPU. Acceptance is kind for the DDP logic, and the part 1 EKS run, with GPU nodes, for everything else.

## Background

Read at `f086d6b` on 2026-09-14. Square-bracket numbers are sources in the research note. The note is `status: final`, but its Verification table doesn't cover [14] or [15], so those are marked *(unverified)*. It doesn't cover [10]'s device-plugin claim either, but that page was re-read on 2026-09-14. Part 1 lands first and rewrites `gpu-ml/README.md:44-74`, so the lines this part cites below line 74 of that file move; each is also given by its text.

- **Cluster name.** Eight GPU files set `CLUSTER_NAME=my-eks-cluster`. They are `gpu-ml/README.md:34`, `gpu-ml/exercises/01-gpu-node-setup/README.md:43`, `gpu-ml/exercises/02-gpu-scheduling/README.md:50`, `gpu-ml/exercises/03-distributed-training/README.md:48`, `gpu-ml/exercises/04-model-serving/README.md:52`, `gpu-ml/exercises/05-gpu-monitoring/README.md:48`, `gpu-ml/exercises/06-storage-for-ml/README.md:49` and `gpu-ml/exercises/07-cost-and-efficiency/README.md:66`. The default name is `k8s-dojo` (`eks/variables.tf:7-11`).
- **Device plugin.**
  - Exercise 01 looks for the plugin with `-l name=nvidia-device-plugin-ds` (`gpu-ml/exercises/01-gpu-node-setup/README.md:101`, `:116`, `:176`), and installs it with Helm only "if not present" (`:103-110`).
  - Exercise 07 patches, and then restarts, a DaemonSet named `nvidia-device-plugin-daemonset` (`gpu-ml/exercises/07-cost-and-efficiency/README.md:82-96`, `:203`). It points the plugin at a config file through a hand-added volume and a `CONFIG_FILE` env var.
  - The knowledge check repeats that name (`gpu-ml/README.md:118`, answer 3, which starts "3. The NVIDIA Device Plugin").
  - According to the chart at commit d415f49 (research [15], *(unverified)*):
    - it names the DaemonSet after the release ([`_helpers.tpl#L14-L24`](https://github.com/NVIDIA/k8s-device-plugin/blob/d415f49223cb9344081cf167461ea0eada141695/deployments/helm/nvidia-device-plugin/templates/_helpers.tpl#L14-L24));
    - it labels it `app.kubernetes.io/name` ([`#L61-L63`](https://github.com/NVIDIA/k8s-device-plugin/blob/d415f49223cb9344081cf167461ea0eada141695/deployments/helm/nvidia-device-plugin/templates/_helpers.tpl#L61-L63));
    - it takes its config through `config.name`/`config.map` ([`values.yaml#L20-L26`](https://github.com/NVIDIA/k8s-device-plugin/blob/d415f49223cb9344081cf167461ea0eada141695/deployments/helm/nvidia-device-plugin/values.yaml#L20-L26)).
  - The chart's default affinity at the same commit schedules the DaemonSet only on nodes labelled `feature.node.kubernetes.io/pci-10de.present=true`, `feature.node.kubernetes.io/cpu-model.vendor_id=NVIDIA` or `nvidia.com/gpu.present=true` ([`values.yaml#L71-L92`](https://github.com/NVIDIA/k8s-device-plugin/blob/d415f49223cb9344081cf167461ea0eada141695/deployments/helm/nvidia-device-plugin/values.yaml#L71-L92), read directly on 2026-09-14). The chart's comments say Node Feature Discovery sets the first two, and this cluster doesn't run it (part 1 Background, "Device-plugin affinity"). So part 1 W3 puts `nvidia.com/gpu.present=true` on the GPU node group, and exercise 01's Helm command, which overrides only the tolerations (`gpu-ml/exercises/01-gpu-node-setup/README.md:106-110`), can keep the default affinity.
  - AL2023 NVIDIA AMIs don't include the plugin ([accelerated AMIs](https://docs.aws.amazon.com/eks/latest/userguide/ml-eks-optimized-ami.html) [10]; the research's Verification table doesn't check this, but the page, read on 2026-09-14, still says it), so on this cluster the Helm install is the normal path, not a fallback.
  - The time-slicing ConfigMap is `device-plugin-config`, with the key `config.yaml` (`gpu-ml/exercises/07-cost-and-efficiency/manifests/time-slicing-configmap.yaml:1-15`).
- **DCGM.**
  - Exercise 05 uses lower-case names such as `dcgm_gpu_utilization` in its metric table (`gpu-ml/exercises/05-gpu-monitoring/README.md:20-30`), and in every query, expected output and prose line (`:91`, `:97`, `:113`, `:117`, `:131-143`, `:158`, `:166`). So do its knowledge check (`:181-194`) and `gpu-ml/README.md:120` (answer 5, which starts "5. `dcgm_gpu_utilization`").
  - The exporter's `default-counters.csv` at commit 16ecae4 lists [`DCGM_FI_DEV_GPU_UTIL`](https://github.com/NVIDIA/dcgm-exporter/blob/16ecae49e4d6174e556e768c87cd4e49d844b909/etc/default-counters.csv#L23) and [`DCGM_FI_DEV_FB_USED`](https://github.com/NVIDIA/dcgm-exporter/blob/16ecae49e4d6174e556e768c87cd4e49d844b909/etc/default-counters.csv#L48) (research [14], *(unverified)*).
  - The Helm chart doesn't use that file. It renders its own list in [`deployment/templates/metrics-configmap.yaml`](https://github.com/NVIDIA/dcgm-exporter/blob/16ecae49e4d6174e556e768c87cd4e49d844b909/deployment/templates/metrics-configmap.yaml) and mounts it over the default ([`deployment/values.yaml#L207-L219`](https://github.com/NVIDIA/dcgm-exporter/blob/16ecae49e4d6174e556e768c87cd4e49d844b909/deployment/values.yaml#L207-L219)). So the chart's list, not the CSV, decides what exercise 05 sees.
  - The research doesn't map the other seven rows (memory-copy utilisation, free memory, temperature, power, PCIe transmit and receive, NVLink).
- **Exercise 03.**
  - The Job is Indexed, with 2 completions and 2 in parallel (`gpu-ml/exercises/03-distributed-training/manifests/distributed-training-job.yaml:5-9`). `RANK` comes from the completion-index annotation (`:22-28`).
  - The script builds a model and computes a loss five times, but never creates a process group, wraps the model in DDP, calls `backward()` or steps an optimiser (`:32-49`). So the loss never changes and the ranks never communicate.
  - The README teaches `MASTER_ADDR`, rendezvous and torchrun (`gpu-ml/exercises/03-distributed-training/README.md:26-41`), and then says the Job "simulates" them (`:104-113`). It expects shard-only output (`:127-132`).
  - Each pod requests one GPU (`gpu-ml/exercises/03-distributed-training/manifests/distributed-training-job.yaml:50-54`), so the run needs two GPU nodes. Part 1 W3 sets the default `max_size` to 2.

## Non-goals

- The platform (part 1) and the core exercises (part 2).
- MIG, Spot nodes and the Node Termination Handler install in exercise 07 (the handler is a P2 row).
- EFS in exercise 06, model serving in exercise 04, and pinning the Prometheus stack chart.
- Multi-GPU-per-node training (`--nproc-per-node` > 1).

## Design

- **Cluster name.** Every GPU README reads it from Terraform with `export CLUSTER_NAME=$(terraform -chdir="$(git rev-parse --show-toplevel)/eks" output -raw cluster_name)`. This works at any directory depth; part 2 uses `../../eks` because its exercises all sit two levels down.
- **Device plugin.** It is always installed by Helm, as release `nvidia-device-plugin` at a pinned chart version. Time-slicing is enabled with `helm upgrade --reuse-values`, not a hand patch.
- **Exercise 03** becomes three documents in one manifest:
  - a headless Service `distributed-training`;
  - a ConfigMap holding `train.py`;
  - the Indexed Job, with `subdomain: distributed-training`, running `torchrun --nnodes=2 --nproc-per-node=1 --node-rank=$JOB_COMPLETION_INDEX --master-addr=distributed-training-0.distributed-training` and `--master-port=29500`.

  `train.py` does the following:
  1. Initialises a process group, with `nccl` on GPU and `gloo` on CPU, and prints `backend=<name> rank=<r> world_size=<n>` from every rank.
  2. Wraps a small model in `DistributedDataParallel`, and shards a seeded synthetic dataset with `DistributedSampler`.
  3. Runs 5 epochs of `backward()` and `optimizer.step()`, printing `epoch <e> loss <value>` on rank 0 after each.
  4. Destroys the process group.

  Kubernetes sets `JOB_COMPLETION_INDEX`, and gives Indexed Job pods the hostname `<job>-<index>`, which resolves under the subdomain *(assumption)*; S4 checks both.

## Work items

### W1: Cluster name and device-plugin install

- **Change:**
  - Replace the eight `CLUSTER_NAME` lines with the Design command.
  - In exercise 01 Step 3:
    - make the pinned `helm upgrade --install` the first command, with the existing tolerations (`gpu-ml/exercises/01-gpu-node-setup/README.md:106-110`), the chart's default affinity (Background), and the chart version from S1;
    - change the three selectors to `app.kubernetes.io/name=nvidia-device-plugin`.
  - Fix knowledge-check answer 3 at `gpu-ml/README.md:118`. After part 1 lands, find it with `grep -n '^3\. The NVIDIA Device Plugin' gpu-ml/README.md`.
- **Files:**
  - `gpu-ml/README.md`
  - `gpu-ml/exercises/01-gpu-node-setup/README.md`
  - `gpu-ml/exercises/02-gpu-scheduling/README.md`
  - `gpu-ml/exercises/03-distributed-training/README.md`
  - `gpu-ml/exercises/04-model-serving/README.md`
  - `gpu-ml/exercises/05-gpu-monitoring/README.md`
  - `gpu-ml/exercises/06-storage-for-ml/README.md`
  - `gpu-ml/exercises/07-cost-and-efficiency/README.md`
- **Done when:**
  - `git grep -n 'my-eks-cluster\|nvidia-device-plugin-ds' gpu-ml` prints nothing.
  - EKS run with one GPU node: after exercise 01 Step 3 runs verbatim, `kubectl get pods -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin -o wide` shows one `Running` pod on the GPU node.
  - `kubectl get node "$GPU_NODE" -o jsonpath='{.status.capacity.nvidia\.com/gpu}'` prints `1`.

### W2: Time-slicing through the chart

- **Change:**
  - Replace the `kubectl patch` and restart steps (`gpu-ml/exercises/07-cost-and-efficiency/README.md:82-96`) with `kubectl apply` of the ConfigMap, followed by `helm upgrade nvidia-device-plugin nvdp/nvidia-device-plugin --version <pinned> --reuse-values` with the config keys S2 finds. The `--version` is needed because Helm doesn't carry the chart version over, so leaving it off would upgrade past the W1 pin. Change the ConfigMap only if S2 needs a different key layout.
  - Clean-up (`:196-204`): unset the config with a second `helm upgrade --version <pinned>`, rather than `rollout restart` on a DaemonSet that doesn't exist.
- **Files:** `gpu-ml/exercises/07-cost-and-efficiency/README.md`, possibly `gpu-ml/exercises/07-cost-and-efficiency/manifests/time-slicing-configmap.yaml`
- **Done when:**
  - `git grep -n 'nvidia-device-plugin-daemonset' gpu-ml` prints nothing.
  - EKS run: after Step 1 runs verbatim, `kubectl get node "$GPU_NODE" -o jsonpath='{.status.capacity.nvidia\.com/gpu}'` prints `4` within 2 minutes. After the clean-up, it prints `1`.

### W3: DCGM metric names

- **Change:**
  - Rewrite the metric table and every query and answer to use the `DCGM_FI_*` names that S3 confirms are in the chart's rendered counters list. `dcgm_gpu_utilization` becomes `DCGM_FI_DEV_GPU_UTIL`, and `dcgm_fb_used` becomes `DCGM_FI_DEV_FB_USED` ([default-counters.csv](https://github.com/NVIDIA/dcgm-exporter/blob/main/etc/default-counters.csv) [14] *(unverified)*).
  - Drop any row that has no default counter, or mark it "needs a custom counters file".
  - Keep the definition of utilisation (`gpu-ml/exercises/05-gpu-monitoring/README.md:34`) only if it matches the counter's description in the CSV.
- **Files:** `gpu-ml/exercises/05-gpu-monitoring/README.md`, `gpu-ml/README.md`
- **Done when:**
  - `git grep -n 'dcgm_[a-z]' gpu-ml` prints nothing.
  - Every `DCGM_FI_` name in the two files appears in `helm template dcgm-exporter gpu-helm-charts/dcgm-exporter --version <pinned> | grep DCGM_FI_` (S3).
  - EKS run: exercise 05 Step 2 prints one `DCGM_FI_DEV_GPU_UTIL{` line.
  - EKS run: the Step 3 Prometheus query returns a non-empty `.data.result`.

### W4: Real DDP in exercise 03

- **Change:**
  - Rewrite `distributed-training-job.yaml` as the three documents in Design. Drop the hand-set `RANK` and `WORLD_SIZE`, which torchrun sets.
  - Add `activeDeadlineSeconds`, so a rendezvous that hangs ends.
  - README:
    - Step 3: drop "simulates", and say to scale the GPU group to 2 first (`aws eks update-nodegroup-config ... desiredSize=2`), at about twice the hourly GPU rate.
    - Expected output: per-rank start lines, and falling loss on rank 0.
    - Step 5: a failed rank now leaves the other waiting at rendezvous until the deadline. That's the same hang knowledge-check answer 3 describes for a missing worker (`gpu-ml/exercises/03-distributed-training/README.md:172`).
    - Clean-up: delete the Service and the ConfigMap too.
- **Files:** `gpu-ml/exercises/03-distributed-training/manifests/distributed-training-job.yaml`, `gpu-ml/exercises/03-distributed-training/README.md`
- **Done when:**
  - On kind, running the manifest with the GPU fields stripped (`yq 'del(.spec.template.spec.nodeSelector, .spec.template.spec.tolerations, .spec.template.spec.containers[0].resources)'` on the Job document) gives `2/2` completions for `kubectl get job distributed-training`, within 10 minutes of the image pull.
  - The rank-0 logs show `backend=gloo` and `world_size=2`, and the `epoch 5 loss` value is below the `epoch 1 loss` value.
  - EKS run with two GPU nodes: the same, with `backend=nccl`.

## Effort

| Item | Estimate | Depends on |
|---|---|---|
| W1 | 1–2 h plus S1 | part 1 W3 |
| W2 | 1 h plus S2 | W1 |
| W3 | 2 h plus S3 | W1 |
| W4 | 3–4 h plus S4 | part 1 W3; part 1 S3 showing 8 vCPUs of GPU quota |

These are estimated from reading the code, so trust the ordering more than the numbers. The EKS checks ride on the part 1 gate run: one GPU node for W1–W3, and two for W4.

## Spike questions

The spikes need Helm 3.14 or later (the version `gpu-ml/README.md:29` asks for) and `yq`; S3 also needs the `helm repo add gpu-helm-charts …` line from `gpu-ml/exercises/05-gpu-monitoring/README.md:66`.

- **S1. What DaemonSet name, pod labels and affinity does the pinned device-plugin chart render?** Run `helm repo add nvdp https://nvidia.github.io/k8s-device-plugin && helm search repo nvdp --versions | head -3`, then `helm template nvidia-device-plugin nvdp/nvidia-device-plugin --version <newest> | yq 'select(.kind=="DaemonSet") | .metadata.name, .spec.template.metadata.labels, .spec.template.spec.affinity'`. No cluster is needed. If the affinity no longer accepts `nvidia.com/gpu.present=true` (Background), W1 adds `--set-json` for an affinity that selects `workload-type=gpu` instead.
- **S2. Which chart values enable time-slicing from an existing ConfigMap, and what key layout do they expect?** Run `helm show values nvdp/nvidia-device-plugin --version <pinned> | yq '.config'`.
- **S3. Which `DCGM_FI_*` names does the pinned dcgm-exporter chart emit by default?** Run `helm template dcgm-exporter gpu-helm-charts/dcgm-exporter --version <newest> | grep DCGM_FI_`, which reads the chart's rendered counters ConfigMap and needs no cluster. Then map the nine table rows (`gpu-ml/exercises/05-gpu-monitoring/README.md:22-30`).
- **S4. Do Indexed Job pods with `subdomain` resolve as `distributed-training-0.distributed-training` before rank 1 connects, and does torchrun retry until they do?** Test it on kind with the CPU variant from W4. If DNS lags, set `publishNotReadyAddresses: true` on the Service.

## Risks and rollback

- **GPU cost.** W4's check needs two GPU nodes. *(Estimate)* Budget an hour, made up of about 3 minutes of scale-up (`gpu-ml/exercises/01-gpu-node-setup/README.md:69`), the first pull of the PyTorch image, and one or two runs of up to 10 minutes each (the W4 Done when budget). The README must say to scale back to 0. Two g4dn.xlarge nodes also need 8 vCPUs of the account's G and VT quota, which defaults to 0 (part 1 Background, "GPU quota"); part 1 S3 checks it, and a short quota blocks W4's EKS check until AWS raises it.
- **Image size.** The `pytorch/pytorch:2.2.0-cuda12.1-cudnn8-runtime` image (`gpu-ml/exercises/03-distributed-training/manifests/distributed-training-job.yaml:21`) is large *(assumption)*, so the kind run's first pull is slow. That affects time, not correctness.
- **Rollback.** Everything here is docs and manifests. Revert per item.

## Open questions

- None.
