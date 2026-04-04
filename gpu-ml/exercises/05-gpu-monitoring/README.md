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

| Metric | Unit | What it means |
|---|---|---|
| `dcgm_gpu_utilization` | % | Streaming Multiprocessor (SM) occupancy — compute activity |
| `dcgm_mem_copy_utilization` | % | Memory controller activity — data movement between CPU and GPU |
| `dcgm_fb_used` | MiB | GPU framebuffer (vRAM) in use |
| `dcgm_fb_free` | MiB | GPU framebuffer (vRAM) free |
| `dcgm_gpu_temp` | °C | GPU die temperature |
| `dcgm_power_usage` | W | Current power draw |
| `dcgm_pcie_tx_throughput` | KB/s | PCIe host-to-device bandwidth |
| `dcgm_pcie_rx_throughput` | KB/s | PCIe device-to-host bandwidth |
| `dcgm_xgmi_l0_tx_throughput` | KB/s | NVLink bandwidth (multi-GPU nodes) |

### Reading GPU utilisation

`dcgm_gpu_utilization` does not measure the fraction of CUDA cores busy — it measures the percentage of time at least one warp was active on any SM over the sampling window. Common patterns:

| Observation | Interpretation |
|---|---|
| SM util high, memory util low | Compute-bound — model is math-limited |
| SM util low, memory util high | Memory-bandwidth-bound — increase batch size |
| Both low during training | Data loading bottleneck — workers starving the GPU |
| Temperature > 85°C | Thermal throttling risk — check cooling and power cap |

---

## Prerequisites

```bash
export CLUSTER_NAME=my-eks-cluster

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

helm upgrade --install dcgm-exporter gpu-helm-charts/dcgm-exporter \
  --namespace monitoring \
  --set tolerations[0].key=nvidia.com/gpu \
  --set tolerations[0].operator=Exists \
  --set tolerations[0].effect=NoSchedule \
  --set nodeSelector."workload-type"=gpu \
  --set serviceMonitor.enabled=true \
  --set serviceMonitor.interval=15s

# Confirm DaemonSet pods are running on GPU nodes
kubectl get pods -n monitoring -l app.kubernetes.io/name=dcgm-exporter -o wide
```

---

## Step 2 — Verify the metrics endpoint

```bash
DCGM_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=dcgm-exporter \
  -o jsonpath='{.items[0].metadata.name}')

# Fetch raw metrics from the exporter
kubectl exec -n monitoring "$DCGM_POD" -- curl -s http://localhost:9400/metrics | grep "^dcgm_gpu_utilization"
```

Expected output (one line per GPU):

```
dcgm_gpu_utilization{gpu="0",UUID="GPU-...",modelName="Tesla T4",...} 0
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
curl -s "http://localhost:9090/api/v1/query?query=dcgm_gpu_utilization" | \
  jq '.data.result[] | {gpu: .metric.gpu, node: .metric.Hostname, value: .value[1]}'

# Query GPU memory usage as a percentage
curl -s "http://localhost:9090/api/v1/query?query=dcgm_fb_used/(dcgm_fb_used+dcgm_fb_free)*100" | \
  jq '.data.result[] | {gpu: .metric.gpu, memory_pct: .value[1]}'

kill $PF_PID
```

---

## Step 4 — Write useful PromQL queries

Save these for dashboards or alert rules:

```promql
# Average GPU utilisation across all GPU nodes (last 5 minutes)
avg_over_time(dcgm_gpu_utilization[5m])

# GPU memory saturation — alert when > 90%
dcgm_fb_used / (dcgm_fb_used + dcgm_fb_free) > 0.90

# GPUs running hot — alert when temperature exceeds 85°C
dcgm_gpu_temp > 85

# GPU power draw — useful for cost attribution
sum by (Hostname) (dcgm_power_usage)

# Detect idle GPUs (allocated but under-utilised)
dcgm_gpu_utilization < 5
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
    grep "^dcgm_gpu_utilization" | awk '{print "GPU util:", $NF, "%"}'
  sleep 5
done

# Clean up
kubectl delete job single-gpu-training --ignore-not-found
```

You should see `dcgm_gpu_utilization` rise while the job runs and drop to 0 when it completes.

---

## Step 6 — Clean up

```bash
helm uninstall dcgm-exporter -n monitoring
# Leave kube-prometheus installed for future exercises
```

---

## Knowledge Check

1. What does `dcgm_gpu_utilization = 100` mean? Does it mean all CUDA cores are busy?
2. A training job reports loss decreasing but `dcgm_gpu_utilization` stays below 20%. What is the most likely cause?
3. `dcgm_fb_used` is at 15.8 GB on a 16 GB T4. The model server is still responding. Should you alert?
4. How would you attribute GPU power costs to individual teams using PromQL labels?
5. A GPU node's temperature hits 87°C during training. What does the GPU do automatically, and what should you investigate?

<details>
<summary>Answers</summary>

1. `dcgm_gpu_utilization = 100` means the GPU had at least one active warp running on at least one SM during every sampling interval — it does not mean all CUDA cores were in use simultaneously. A GPU with 5,000 cores could show 100% utilisation while using only 500 cores if a warp was consistently active. It is an activity metric, not a saturation metric.
2. The GPU is starved of data — the data loading pipeline (CPU preprocessing, disk I/O, host-to-device transfers) cannot feed batches fast enough. Increase `num_workers` in the DataLoader, use pinned memory (`pin_memory=True`), or prefetch data to the GPU in advance.
3. Yes — at 98.75% vRAM usage the risk of OOM on the next large allocation (e.g. a batch with more tokens than expected) is high. Alert at 90% to give time to respond before the process crashes.
4. Add a label to GPU nodes identifying the team (e.g. `team=nlp`) and use `sum by (team) (dcgm_power_usage * on(instance) group_left(team) kube_node_labels)` to aggregate power draw per team across all their GPU nodes.
5. The GPU automatically reduces its clock speed (thermal throttling) to stay within its thermal envelope. Investigate: airflow and cooling in the data centre rack, instance type (some instance families have better cooling), whether the training batch size can be reduced to lower sustained power draw, and whether `dcgm_power_usage` is approaching the GPU's TDP limit.

</details>
