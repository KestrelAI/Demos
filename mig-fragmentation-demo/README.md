# MIG Fragmentation Demo

This demo creates a GPU resource fragmentation scenario on Kubernetes clusters running NVIDIA A100 or H100 GPUs with Multi-Instance GPU (MIG) enabled.

## Overview

MIG allows multiple workloads to share a single physical GPU by partitioning it into isolated instances. However, MIG instances must be created from **contiguous GPU slices**, which leads to fragmentation over time.

This demo deploys:
1. **Inference pods** requesting small `1g.5gb` MIG instances (scattered across GPUs)
2. **A training job** requesting a medium `2g.10gb` MIG instance (will fail to schedule)
3. **Additional fragmenter pods** to maximize fragmentation

The training job will remain in `Pending` state due to MIG fragmentation - even though there's plenty of GPU memory "available", there are no 2 contiguous slices free on any GPU.

## Prerequisites

- **NVIDIA A100 or H100 GPUs** - MIG is only available on these architectures (T4, V100, L4 won't work)
- MIG mode enabled on the GPU nodes
- [Kestrel Operator](https://github.com/KestrelAI/Kestrel-Operator) deployed
- Helm 3.x

### Setting Up a GKE Cluster with MIG (Recommended)

To demonstrate MIG fragmentation, we need the **NVIDIA GPU Operator** with `mixed` MIG strategy. This allows different pods to request different MIG profiles dynamically.

**Important:** GKE requires specific configuration for the GPU Operator due to Container-Optimized OS (COS) filesystem constraints. The configuration below has been tested and verified to work.

```bash
# Step 1: Create a GKE Standard cluster with A100 GPUs
# Do NOT use --gpu-partition-size (we want dynamic MIG via GPU Operator)
gcloud container clusters create mig-demo-cluster \
  --zone us-central1-a \
  --machine-type a2-highgpu-1g \
  --accelerator type=nvidia-tesla-a100,count=1 \
  --num-nodes=1 \
  --release-channel rapid

# Step 2: Create PriorityClass for GPU Operator
# GKE has ResourceQuota that blocks system-critical PriorityClasses
cat <<EOF | kubectl apply -f -
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: nvidia-gpu-operator
value: 100000
globalDefault: false
description: "Priority for NVIDIA GPU Operator components"
EOF

# Step 3: Install NVIDIA GPU Operator with GKE-specific settings
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

# Key settings for GKE:
#   - driver.enabled=false: Use GKE's pre-installed NVIDIA drivers
#   - toolkit.installDir: Use exec-capable path (COS mounts /var with noexec)
#   - hostPaths.driverInstallDir: Where GKE installs NVIDIA drivers
#   - dcgmExporter.enabled=false: DCGM profiling fails on GKE; not needed for MIG
#   - Custom PriorityClass to avoid GKE ResourceQuota restrictions
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --create-namespace \
  --set driver.enabled=false \
  --set toolkit.installDir=/home/kubernetes/bin/nvidia-toolkit \
  --set hostPaths.driverInstallDir=/home/kubernetes/bin/nvidia \
  --set mig.strategy=mixed \
  --set migManager.enabled=true \
  --set migManager.env[0].name=MIG_PARTED_REBOOT_IF_REQUIRED \
  --set migManager.env[0].value=true \
  --set migManager.env[1].name=WITH_REBOOT \
  --set migManager.env[1].value=true \
  --set dcgmExporter.enabled=false \
  --set daemonsets.priorityClassName=nvidia-gpu-operator \
  --set operator.priorityClassName=nvidia-gpu-operator \
  --set node-feature-discovery.priorityClassName=nvidia-gpu-operator

# Step 4: Enable MIG mode on the GPU node
# Wait for GPU Operator pods to be running
kubectl get pods -n gpu-operator -w

# Once nvidia-mig-manager is running, apply MIG configuration
# This creates 7x 1g.5gb MIG instances on the A100
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl label node $NODE nvidia.com/mig.config=all-1g.5gb --overwrite

# The MIG Manager will reboot the node to enable MIG mode
# Wait for the node to come back up (2-3 minutes)
kubectl get nodes -w

# Verify MIG is configured (should show "success")
kubectl get node $NODE -o jsonpath='{.metadata.labels}' | grep mig.config.state
```

**Why these settings?**
- `driver.enabled=false` - GKE pre-installs NVIDIA drivers on GPU nodes
- `toolkit.installDir=/home/kubernetes/bin/nvidia-toolkit` - COS mounts `/var` with noexec; this path is exec-capable
- `hostPaths.driverInstallDir` - Points to GKE's driver installation location
- `MIG_PARTED_REBOOT_IF_REQUIRED=true` - Allows MIG Manager to reboot node to enable MIG mode
- `dcgmExporter.enabled=false` - DCGM profiling fails on GKE; not needed for MIG
- Custom PriorityClass - GKE's ResourceQuota blocks pods with `system-node-critical` PriorityClass

The `mig.strategy=mixed` setting enables dynamic MIG partitioning - pods can request different profiles and the operator creates them on-demand.

**⚠️ Cost Warning:** A100 GPUs are expensive (~$3-4/hour per node). This demo only needs a few minutes - delete the cluster when done.

### Verify GPU Operator is Ready

Wait for all GPU Operator pods to be running (this may take 2-3 minutes):

```bash
# Watch GPU Operator pods come up
kubectl get pods -n gpu-operator -w

# You should see these pods running:
# - gpu-operator (controller)
# - nvidia-container-toolkit-daemonset
# - nvidia-device-plugin-daemonset
# - nvidia-mig-manager
# - gpu-feature-discovery
# - nvidia-operator-validator

# Verify MIG strategy is configured
kubectl get nodes -o jsonpath='{.items[0].metadata.labels}' | jq . | grep mig

# Check node GPU capacity
kubectl get nodes -o json | jq '.items[].status.allocatable | with_entries(select(.key | contains("nvidia")))'
```

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/KestrelAI/Demos.git
   cd Demos/mig-fragmentation-demo
   ```

2. Deploy the demo:
   ```bash
   helm install mig-demo ./chart --namespace mig-demo --create-namespace
   ```

3. Watch the pods:
   ```bash
   kubectl get pods -n mig-demo -w
   ```

You should see:
- 4 inference pods running (consuming `1g.5gb` slices)
- 2 fragmenter pods running (consuming more `1g.5gb` slices)
- 1 training job stuck in `Pending`

## Observing the Fragmentation

Check why the training job can't schedule:

```bash
kubectl describe pod -n mig-demo -l app=mig-training
```

You'll see:
```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  30s   default-scheduler  0/2 nodes are available: 
           2 Insufficient nvidia.com/mig-2g.10gb.
```

Check the node's MIG capacity:
```bash
kubectl get nodes -o=custom-columns='NAME:.metadata.name,MIG-1G-5GB:.status.allocatable.nvidia\.com/mig-1g\.5gb,MIG-2G-10GB:.status.allocatable.nvidia\.com/mig-2g\.10gb'
```

## Kestrel Detection

Within 2 minutes, Kestrel will:
1. Detect the scheduling failure incident
2. Investigate the root cause (MIG fragmentation)
3. Generate fix options:
   - Preempt low-priority inference pods
   - Adjust the training job's MIG profile
   - Reconfigure MIG partitions on the node

## Resolving the Fragmentation

The fix is to **free contiguous GPU slices** so the MIG Manager can create a `2g.10gb` partition.

### Option 1: Evict Inference Pods (Recommended)

Evict 2 inference pods to free enough contiguous slices:

```bash
# Delete 2 inference pods to free contiguous slices
kubectl get pods -n mig-demo -l app=mig-inference -o name | head -2 | xargs kubectl delete -n mig-demo

# Watch the training job - it should transition to Running within 30-60 seconds
kubectl get pods -n mig-demo -w
```

After eviction, the GPU Operator's MIG Manager will:
1. Destroy the freed `1g.5gb` MIG instances
2. Create a `2g.10gb` instance from the contiguous slices
3. Schedule the training job

### Option 2: Use PriorityClass Preemption

The chart already creates PriorityClasses (`gpu-training-high` and `gpu-inference-low`). Delete and recreate the training job to trigger preemption:

```bash
kubectl delete job mig-demo-training -n mig-demo
# Recreate - the scheduler will preempt low-priority inference pods
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: mig-demo-training
  namespace: mig-demo
spec:
  template:
    spec:
      priorityClassName: gpu-training-high
      restartPolicy: Never
      containers:
      - name: training
        image: nvcr.io/nvidia/pytorch:24.01-py3
        command: ["python", "-c", "import time; print('Training running'); time.sleep(3600)"]
        resources:
          requests:
            nvidia.com/mig-2g.10gb: 1
          limits:
            nvidia.com/mig-2g.10gb: 1
EOF
```

### Option 3: Reduce Training MIG Profile

If the training workload can run on a smaller slice:

```bash
# Update training to use 1g.5gb instead of 2g.10gb
helm upgrade mig-demo ./chart \
  --set training.resources.requests."nvidia\.com/mig-2g\.10gb"=null \
  --set training.resources.requests."nvidia\.com/mig-1g\.5gb"=1 \
  --set training.resources.limits."nvidia\.com/mig-2g\.10gb"=null \
  --set training.resources.limits."nvidia\.com/mig-1g\.5gb"=1
```

## Cleanup

```bash
# Remove the demo workloads
helm uninstall mig-demo --namespace mig-demo
kubectl delete namespace mig-demo

# If you created a GKE cluster for this demo, delete it to stop charges
gcloud container clusters delete mig-demo-cluster --zone us-central1-a --quiet
```

## Configuration

See [values.yaml](./chart/values.yaml) for all configuration options.

Key parameters:
| Parameter | Description | Default |
|-----------|-------------|---------|
| `inference.replicas` | Number of inference pods | `4` |
| `inference.migProfile` | MIG profile for inference | `nvidia.com/mig-1g.5gb` |
| `training.migProfile` | MIG profile for training | `nvidia.com/mig-2g.10gb` |
| `fragmenter.replicas` | Additional fragmenter pods | `2` |
| `priorityClasses.enabled` | Create PriorityClasses | `true` |

## Learn More

- [Blog Post: MIG Fragmentation Explained](https://usekestrel.ai/blog/mig-fragmentation-demo)
- [NVIDIA MIG User Guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/)
- [Kestrel Operator](https://github.com/KestrelAI/Kestrel-Operator)
