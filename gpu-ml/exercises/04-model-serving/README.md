# Exercise 04 — Model Serving

## Learning Objectives

By the end of this exercise you will be able to:

- Deploy a GPU-backed model server with correct resource limits and health probes
- Explain why a startup probe is needed for model serving and how to tune it
- Send inference requests to a running model server
- Describe the tradeoffs between GPU utilisation and latency in serving deployments

---

## Background

Model serving differs from training in three important ways:

| Property | Training | Serving |
|---|---|---|
| Workload type | Batch Job | Long-running Deployment |
| GPU utilisation | Sustained high (70–100%) | Bursty (0–100% per request) |
| Startup time | Fast (seconds) | Slow (model load: 10s–minutes) |
| Failure handling | Retry with backoffLimit | Probe-gated readiness |

### Probe strategy for model servers

Model servers load weights into GPU memory at startup. Until the weights are loaded, the server cannot respond to inference requests. Three probes matter:

| Probe | Role |
|---|---|
| `startupProbe` | Blocks readiness/liveness checks until the model finishes loading. Set `failureThreshold * periodSeconds` to exceed your worst-case load time. |
| `readinessProbe` | Removes the pod from Service endpoints if it cannot serve. Use this to gate traffic. |
| `livenessProbe` | Restarts the container if it becomes permanently stuck (e.g. GPU OOM lock-up). |

### GPU memory and batch size

A single T4 GPU (16 GB vRAM) can hold:

| Model | Precision | vRAM |
|---|---|---|
| GPT-2 (117M) | FP32 | ~0.5 GB |
| LLaMA-2 7B | FP16 | ~14 GB |
| LLaMA-2 13B | FP16 | ~26 GB (does not fit a single T4) |

Requesting `nvidia.com/gpu: 1` on a T4 node gives the pod access to the full 16 GB. The container sees the GPU via `/dev/nvidia0`.

---

## Prerequisites

```bash
export CLUSTER_NAME=my-eks-cluster

GPU_NODE=$(kubectl get nodes -l workload-type=gpu -o jsonpath='{.items[0].metadata.name}')
echo "GPU node: $GPU_NODE"
kubectl describe node "$GPU_NODE" | grep "nvidia.com/gpu"
```

---

## Step 1 — Deploy the model server

This exercise uses a lightweight FastAPI inference server as a stand-in for a production model server (Triton, TorchServe, vLLM):

```bash
kubectl apply -f manifests/model-server-deployment.yaml
kubectl apply -f manifests/model-server-service.yaml

# Watch pod come up — startup probe gates readiness
kubectl get pods -l app=model-server -w
```

The pod will show `0/1 READY` while the startup probe is failing (model loading). Once the startup probe succeeds, the readiness probe takes over and the pod becomes `1/1 READY`.

---

## Step 2 — Inspect probe behaviour during startup

```bash
POD=$(kubectl get pods -l app=model-server -o jsonpath='{.items[0].metadata.name}')

# Watch events as probes run
kubectl describe pod "$POD" | grep -A 20 "Events:"
```

You will see startup probe failures logged until the model finishes loading — this is expected. The pod is not restarted because `startupProbe.failureThreshold` has not been reached.

---

## Step 3 — Send an inference request

```bash
# Port-forward to the model server
kubectl port-forward svc/model-server 8080:80 &
PF_PID=$!

# Wait for port-forward to be ready
sleep 2

# Send a test inference request
curl -s -X POST http://localhost:8080/predict \
  -H "Content-Type: application/json" \
  -d '{"input": [1.0, 2.0, 3.0, 4.0, 5.0]}' | jq .

# Clean up port-forward
kill $PF_PID
```

Expected response:

```json
{
  "prediction": 0.842,
  "device": "cuda:0",
  "latency_ms": 2.1
}
```

If `device` shows `cpu`, the server did not receive a GPU allocation — check the Deployment's resource requests.

---

## Step 4 — Check GPU memory usage

```bash
kubectl exec -it "$POD" -- nvidia-smi --query-gpu=name,memory.used,memory.free,utilization.gpu --format=csv,noheader
```

During idle serving you should see low `utilization.gpu` (< 5%) and steady `memory.used` (the model weights are held in GPU memory at all times, even between requests).

---

## Step 5 — Observe GPU utilisation under load

Run a small load test:

```bash
kubectl port-forward svc/model-server 8080:80 &
PF_PID=$!
sleep 2

# 50 sequential requests
for i in $(seq 1 50); do
  curl -s -X POST http://localhost:8080/predict \
    -H "Content-Type: application/json" \
    -d "{\"input\": [$(shuf -i 1-10 -n 5 | tr '\n' ',' | sed 's/,$//')]}}" \
    > /dev/null
done

kill $PF_PID

# GPU utilisation during the load test
kubectl exec -it "$POD" -- nvidia-smi dmon -s u -d 1 -c 5
```

`SM%` (streaming multiprocessor utilisation) should spike during requests and return to near-zero between them — characteristic of serving workloads.

---

## Step 6 — Clean up

```bash
kubectl delete deployment model-server --ignore-not-found
kubectl delete service model-server --ignore-not-found
```

---

## Knowledge Check

1. Why does a model server need a `startupProbe` that a typical web server does not?
2. A model server pod is `Running` but not `Ready`. Traffic is not being sent to it. Which probe is failing?
3. What is the formula for calculating the maximum model load time a `startupProbe` will tolerate before restarting the container?
4. GPU utilisation shows 0% between inference requests but the model server is working correctly. Why?
5. Your model server serves requests at 50ms p99 latency with one replica. Adding a second replica does not improve throughput. What is the likely bottleneck?
6. A pod requests `nvidia.com/gpu: 1` on a node with a 16 GB T4. The model requires 18 GB of vRAM. What happens?

<details>
<summary>Answers</summary>

1. A model server loads neural network weights (potentially gigabytes) into GPU memory before it can serve any request. This load can take tens of seconds to minutes. A `startupProbe` with a large `failureThreshold` delays the readiness and liveness probes, preventing Kubernetes from restarting the container prematurely while the model is loading.
2. The `readinessProbe`. When a readiness probe fails, the pod is removed from the Service's endpoint list (traffic stops) but the container is not restarted. The `livenessProbe` controls restarts; the `readinessProbe` controls traffic routing.
3. `startupProbe.failureThreshold × startupProbe.periodSeconds`. For example, `failureThreshold: 30` and `periodSeconds: 10` gives a 300-second (5-minute) window before Kubernetes considers the startup failed and restarts the container.
4. GPU compute (SM units) is idle between requests — the GPU is parked waiting for the next inference call. The model weights remain in GPU memory the whole time (reflected in `memory.used`), but no compute is happening. This is normal for latency-optimised serving with low request rate.
5. The bottleneck is likely single-threaded request handling on the model server itself, not GPU capacity. A single GPU handles requests sequentially; a second replica adds another sequential queue rather than parallelising within a single request. The fix is either to enable batching in the model server or to use async request handling (e.g. Triton's dynamic batching).
6. The pod is scheduled and the container starts, but when the model server attempts to allocate 18 GB on the 16 GB GPU, the CUDA `cudaMalloc` call fails with an out-of-memory error. The pod enters `CrashLoopBackOff`. Kubernetes has no visibility into vRAM capacity — `nvidia.com/gpu: 1` allocates the device, not a specific amount of vRAM.

</details>
