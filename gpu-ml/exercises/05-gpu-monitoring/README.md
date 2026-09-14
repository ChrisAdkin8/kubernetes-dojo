# Exercise 05 — GPU Monitoring

## Learning Objectives

By the end of this exercise you will be able to:

- Install DCGM Exporter on GPU nodes via Helm
- Identify the key GPU metrics exposed and what they indicate
- Query GPU metrics using `kubectl exec` and PromQL
- Write alerting thresholds for GPU utilisation and memory pressure

---

## Background

The NVIDIA Data Centre GPU Manager (DCGM) Exporter is a DaemonSet that runs on GPU nodes and exposes GPU telemetry in Prometheus format. It queries the NVIDIA Management Library (NVML) and surfaces metrics on a `/metrics` endpoint.

### Key metrics

DCGM Exporter names each metric after its DCGM field ID. These are all in the counters list the Helm chart installs by default (chart 4.8.3):

| Metric | Unit | What it means |
|---|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | % | Percent of time one or more kernels was running on the GPU |
| `DCGM_FI_DEV_MEM_COPY_UTIL` | % | Percent of time device memory (vRAM) was being read or written |
| `DCGM_FI_DEV_FB_USED` | MiB | GPU framebuffer (vRAM) in use |
| `DCGM_FI_DEV_FB_FREE` | MiB | GPU framebuffer (vRAM) free |
| `DCGM_FI_DEV_GPU_TEMP` | °C | GPU temperature |
| `DCGM_FI_DEV_POWER_USAGE` | W | Current power draw |
| `DCGM_FI_PROF_PCIE_TX_BYTES` | bytes/s | PCIe transmit rate, including protocol headers (a profiling metric) |
| `DCGM_FI_PROF_PCIE_RX_BYTES` | bytes/s | PCIe receive rate, including protocol headers (a profiling metric) |
| `DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL` | counter | NVLink bandwidth across all lanes; only meaningful on multi-GPU nodes with NVLink, not g4dn |

### Reading GPU utilisation

`DCGM_FI_DEV_GPU_UTIL` does not measure the fraction of CUDA cores busy. It is NVML's GPU utilisation: the percentage of the sample period during which one or more kernels was executing ([NVML `nvmlUtilization_t`](https://github.com/NVIDIA/go-nvml/blob/e5441f354b4c7dea74ad35ebe22b774bb5c36ec5/gen/nvml/nvml.h#L245-L249)). A single small kernel running all the time reads 100%. `DCGM_FI_DEV_MEM_COPY_UTIL` is the matching memory figure: the percentage of time device memory was being read or written. It measures vRAM bandwidth activity, not how much vRAM is in use (that's `DCGM_FI_DEV_FB_USED`). Common patterns:

| Observation | Interpretation |
|---|---|
| `GPU_UTIL` high, `MEM_COPY_UTIL` low | Compute-bound — model is math-limited |
| `GPU_UTIL` low, `MEM_COPY_UTIL` high | Memory-bandwidth-bound — increase batch size |
| Both low during training | Data loading bottleneck — workers starving the GPU |
| Temperature > 85°C | Thermal throttling risk — check cooling and power cap |

---

## Prerequisites

```bash
export CLUSTER_NAME=$(terraform -chdir="$(git rev-parse --show-toplevel)/eks" output -raw cluster_name)

# Confirm Prometheus is installed (or install it)
kubectl get svc -n monitoring | grep prometheus

# If not present:
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set prometheus.prometheusSpec.scrapeInterval=15s
```

---

## Step 1 — Install DCGM Exporter

```bash
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo update

# serviceMonitor.additionalLabels.release must match the kube-prometheus-stack
# release name (kube-prometheus above): by default its Prometheus only picks
# up ServiceMonitors with that label.
helm upgrade --install dcgm-exporter gpu-helm-charts/dcgm-exporter \
  --version 4.8.3 \
  --namespace monitoring \
  --set 'tolerations[0].key=nvidia.com/gpu' \
  --set 'tolerations[0].operator=Exists' \
  --set 'tolerations[0].effect=NoSchedule' \
  --set nodeSelector."workload-type"=gpu \
  --set serviceMonitor.enabled=true \
  --set serviceMonitor.interval=15s \
  --set serviceMonitor.additionalLabels.release=kube-prometheus

# Confirm DaemonSet pods are running on GPU nodes
kubectl get pods -n monitoring -l app.kubernetes.io/name=dcgm-exporter -o wide
```

---

## Step 2 — Verify the metrics endpoint

```bash
DCGM_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=dcgm-exporter \
  -o jsonpath='{.items[0].metadata.name}')

# Fetch raw metrics from the exporter
kubectl exec -n monitoring "$DCGM_POD" -- curl -s http://localhost:9400/metrics | grep "^DCGM_FI_DEV_GPU_UTIL{"
```

Expected output (one line per GPU):

```
DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-...",modelName="Tesla T4",...} 0
```

A value of `0` is expected at idle. Run a GPU workload (e.g. the training Job from exercise 03) and re-query to see utilisation rise.

---

## Step 3 — Query metrics via Prometheus

```bash
# Port-forward Prometheus
kubectl port-forward -n monitoring svc/kube-prometheus-kube-prome-prometheus 9090:9090 &
PF_PID=$!
sleep 2

# Query GPU utilisation for all GPUs
curl -sG http://localhost:9090/api/v1/query --data-urlencode 'query=DCGM_FI_DEV_GPU_UTIL' | \
  jq '.data.result[] | {gpu: .metric.gpu, node: .metric.Hostname, value: .value[1]}'

# Query GPU memory usage as a percentage. --data-urlencode matters here:
# an unencoded + in a URL is read as a space.
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=DCGM_FI_DEV_FB_USED / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) * 100' | \
  jq '.data.result[] | {gpu: .metric.gpu, memory_pct: .value[1]}'

kill $PF_PID
```

---

## Step 4 — Write useful PromQL queries

Save these for dashboards or alert rules:

```promql
# Average GPU utilisation across all GPU nodes (last 5 minutes)
avg_over_time(DCGM_FI_DEV_GPU_UTIL[5m])

# GPU memory saturation — alert when > 90%
DCGM_FI_DEV_FB_USED / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) > 0.90

# GPUs running hot — alert when temperature exceeds 85°C
DCGM_FI_DEV_GPU_TEMP > 85

# GPU power draw — useful for cost attribution
sum by (Hostname) (DCGM_FI_DEV_POWER_USAGE)

# Detect idle GPUs (allocated but under-utilised)
DCGM_FI_DEV_GPU_UTIL < 5
```

---

## Step 5 — Observe a live training workload

```bash
# Start a training Job from exercise 03
kubectl apply -f ../03-distributed-training/manifests/single-gpu-job.yaml

# Poll GPU utilisation every 5 seconds while the job runs
for i in $(seq 1 12); do
  kubectl exec -n monitoring "$DCGM_POD" -- \
    curl -s http://localhost:9400/metrics | \
    grep "^DCGM_FI_DEV_GPU_UTIL{" | awk '{print "GPU util:", $NF, "%"}'
  sleep 5
done

# Clean up
kubectl delete job single-gpu-training --ignore-not-found
```

You should see `DCGM_FI_DEV_GPU_UTIL` rise while the job runs and drop to 0 when it completes.

---

## Step 6 — Clean up

```bash
helm uninstall dcgm-exporter -n monitoring
# Leave kube-prometheus installed for future exercises
```

---

## Knowledge Check

1. What does `DCGM_FI_DEV_GPU_UTIL = 100` mean? Does it mean all CUDA cores are busy?
2. A training job reports loss decreasing but `DCGM_FI_DEV_GPU_UTIL` stays below 20%. What is the most likely cause?
3. `DCGM_FI_DEV_FB_USED` is at 15.8 GB on a 16 GB T4. The model server is still responding. Should you alert?
4. How would you attribute GPU power costs to individual teams using PromQL labels?
5. A GPU node's temperature hits 87°C during training. What does the GPU do automatically, and what should you investigate?

<details>
<summary>Answers</summary>

1. `DCGM_FI_DEV_GPU_UTIL = 100` means one or more kernels was executing on the GPU for the whole sample period — it does not mean all CUDA cores were in use. A single small kernel that keeps a fraction of the SMs busy all the time also reads 100%. It is an activity metric, not a saturation metric. To see how much of the GPU is busy, you need a profiling field such as `DCGM_FI_PROF_SM_ACTIVE`, which the chart's default counters list leaves commented out, so it needs a custom counters file.
2. The GPU is starved of data — the data loading pipeline (CPU preprocessing, disk I/O, host-to-device transfers) cannot feed batches fast enough. Increase `num_workers` in the DataLoader, use pinned memory (`pin_memory=True`), or prefetch data to the GPU in advance.
3. Yes — at 98.75% vRAM usage the risk of OOM on the next large allocation (e.g. a batch with more tokens than expected) is high. Alert at 90% to give time to respond before the process crashes.
4. Add a label to GPU nodes identifying the team (e.g. `team=nlp`) and use `sum by (team) (DCGM_FI_DEV_POWER_USAGE * on(instance) group_left(team) kube_node_labels)` to aggregate power draw per team across all their GPU nodes.
5. The GPU automatically reduces its clock speed (thermal throttling) to stay within its thermal envelope. Investigate: airflow and cooling in the data centre rack, instance type (some instance families have better cooling), whether the training batch size can be reduced to lower sustained power draw, and whether `DCGM_FI_DEV_POWER_USAGE` is approaching the GPU's TDP limit.

</details>
