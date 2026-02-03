# EKS Pod Anti-Affinity Scheduling Demo

This demo shows how **required pod anti-affinity** causes scheduling failures when scaling beyond the available node count. It's a common production issue that works perfectly in dev/staging but fails under production load.

## The Scenario

A platform team adds pod anti-affinity to a critical payments service for resilience:

> "If a node goes down, we don't want to lose multiple payment pods at once."

They use `requiredDuringSchedulingIgnoredDuringExecution` (strict) instead of `preferredDuringSchedulingIgnoredDuringExecution` (flexible), thinking stricter is safer.

**What happens:**

| Environment | Replicas | Nodes | Result |
|-------------|----------|-------|--------|
| Dev/Staging | 2-3 | 5 | Works fine |
| Production (normal) | 4 | 4 | Works fine |
| Production (traffic spike) | 8 | 4 | **4 pods stuck Pending forever** |

## The Problem

```yaml
# This anti-affinity configuration causes the issue
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:  # REQUIRED = must obey
      - labelSelector:
          matchLabels:
            app: payments-api
        topologyKey: kubernetes.io/hostname  # One pod per node
```

When HPA tries to scale to 8 replicas but only 4 nodes exist:
- Pods 1-4: Scheduled successfully (one per node)
- Pods 5-8: **Stuck in Pending forever**

```
$ kubectl get pods -n payments
NAME                           READY   STATUS    RESTARTS   AGE
payments-api-7d4f8b6c9-abc12   1/1     Running   0          5m
payments-api-7d4f8b6c9-def34   1/1     Running   0          5m
payments-api-7d4f8b6c9-ghi56   1/1     Running   0          5m
payments-api-7d4f8b6c9-jkl78   1/1     Running   0          5m
payments-api-7d4f8b6c9-mno90   0/1     Pending   0          5m   # Stuck!
payments-api-7d4f8b6c9-pqr12   0/1     Pending   0          5m   # Stuck!
payments-api-7d4f8b6c9-stu34   0/1     Pending   0          5m   # Stuck!
payments-api-7d4f8b6c9-vwx56   0/1     Pending   0          5m   # Stuck!
```

The event shows:
```
0/4 nodes are available: 4 node(s) didn't match pod anti-affinity rules.
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    EKS Cluster (4 nodes - fixed size)                   │
│                                                                         │
│   ┌───────────────┐  ┌───────────────┐  ┌───────────────┐  ┌──────────────┐  │
│   │    Node 1     │  │    Node 2     │  │    Node 3     │  │    Node 4    │  │
│   │ ┌───────────┐ │  │ ┌───────────┐ │  │ ┌───────────┐ │  │ ┌──────────┐ │  │
│   │ │  pod-1    │ │  │ │  pod-2    │ │  │ │  pod-3    │ │  │ │  pod-4   │ │  │
│   │ │  Running  │ │  │ │  Running  │ │  │ │  Running  │ │  │ │  Running │ │  │
│   │ └───────────┘ │  │ └───────────┘ │  │ └───────────┘ │  │ └──────────┘ │  │
│   └───────────────┘  └───────────────┘  └───────────────┘  └──────────────┘  │
│                                                                         │
│   HPA wants 8 replicas, but anti-affinity blocks scheduling:            │
│                                                                         │
│   pod-5: ⏳ Pending - "0/4 nodes available: anti-affinity rules"        │
│   pod-6: ⏳ Pending - "0/4 nodes available: anti-affinity rules"        │
│   pod-7: ⏳ Pending - "0/4 nodes available: anti-affinity rules"        │
│   pod-8: ⏳ Pending - "0/4 nodes available: anti-affinity rules"        │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- AWS account with EKS, EC2, VPC, IAM permissions
- Terraform >= 1.0
- AWS CLI configured (`aws sts get-caller-identity` works)
- kubectl installed
- ~15-20 minutes for EKS cluster creation

## Resources Created

| Resource | Purpose |
|----------|---------|
| EKS Cluster | Kubernetes control plane |
| Node Group (4 nodes) | Fixed-size worker nodes (t3.medium) |
| VPC + Subnets | Network infrastructure |
| Deployment | payments-api with required anti-affinity |
| HPA | Scales to 8 replicas (more than nodes!) |
| Metrics Server | Required for HPA CPU metrics |

**Estimated Cost:** ~$0.40/hour (EKS + 4x t3.medium)

## Quick Start

### 1. Deploy the Infrastructure

```bash
cd eks-anti-affinity-demo
terraform init
terraform apply -auto-approve
```

> EKS takes ~15-20 minutes to provision.

### 2. Configure kubectl

```bash
$(terraform output -raw kubeconfig_command)
```

### 3. Run the Demo

```bash
./scripts/run_demo.sh
```

This will:
1. Show the initial healthy state (2 pods, 4 nodes)
2. Scale to 8 replicas
3. Show pods stuck in Pending
4. Display the scheduling failure events

### 4. Apply the Fix

```bash
./scripts/apply_fix.sh
```

This patches the deployment to use `preferred` instead of `required` anti-affinity.

## Manual Demo Steps

### Check Initial State

```bash
# Nodes available
kubectl get nodes

# Pods running (should be 2)
kubectl get pods -n payments -o wide

# HPA configuration
kubectl get hpa -n payments
```

### Trigger the Issue

```bash
# Scale beyond node count
kubectl scale deployment payments-api -n payments --replicas=8

# Watch pods (4 will be Pending)
kubectl get pods -n payments -w

# See why they're pending
kubectl get events -n payments --field-selector reason=FailedScheduling
```

### Apply the Fix

**Option 1: Strategic Merge Patch (Recommended for Production)**

Create a file `payments-api-deployment-fix.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
spec:
  template:
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: payments-api
                topologyKey: kubernetes.io/hostname
```

Apply it:

```bash
kubectl apply -f payments-api-deployment-fix.yaml
```

**Option 2: JSON Patch (One-liner)**

```bash
kubectl patch deployment payments-api -n payments --type='json' -p='[
  {
    "op": "remove",
    "path": "/spec/template/spec/affinity/podAntiAffinity/requiredDuringSchedulingIgnoredDuringExecution"
  },
  {
    "op": "add",
    "path": "/spec/template/spec/affinity/podAntiAffinity/preferredDuringSchedulingIgnoredDuringExecution",
    "value": [{
      "weight": 100,
      "podAffinityTerm": {
        "labelSelector": {
          "matchLabels": {
            "app": "payments-api"
          }
        },
        "topologyKey": "kubernetes.io/hostname"
      }
    }]
  }
]'
```

**Option 3: Add more nodes**

```bash
aws eks update-nodegroup-config \
  --cluster-name $(terraform output -raw cluster_name) \
  --nodegroup-name $(terraform output -raw cluster_name)-nodes \
  --scaling-config minSize=4,maxSize=8,desiredSize=8
```

## The Fix Explained

### Before (Causes Scheduling Failures)

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: payments-api
        topologyKey: kubernetes.io/hostname
```

**Behavior:** Pods MUST be on different nodes. If not possible, stay Pending forever.

### After (Flexible Scheduling)

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app: payments-api
          topologyKey: kubernetes.io/hostname
```

**Behavior:** TRY to put pods on different nodes. If not possible, schedule anyway.

You still get resilience benefits when capacity allows, but scaling isn't blocked during traffic spikes.

## Why This Works in Dev but Fails in Prod

| Factor | Dev/Staging | Production |
|--------|-------------|------------|
| Replicas | 2-3 | 4-8+ (HPA scales up) |
| Nodes | Often oversized | Right-sized for cost |
| Traffic | Low, consistent | Spikes during peaks |
| Testing | Manual, low load | Real user traffic |

The anti-affinity constraint is never hit in dev because replicas never exceed nodes.

## Cleanup

```bash
terraform destroy -auto-approve
```

## How Kestrel Helps

[Kestrel AI](https://usekestrel.ai) automatically detects this issue and generates the fix:

### Detection

Kestrel identifies the incident as a **Rollout Failure** by:

1. **Monitoring FailedScheduling events** - Detects `0/4 nodes are available: 4 node(s) didn't match pod anti-affinity rules`
2. **Correlating with deployment config** - Identifies the `requiredDuringSchedulingIgnoredDuringExecution` anti-affinity as the root cause
3. **Tracing the chain of events** - Shows deployment creation → initial pod scheduling → scheduling failures

### Root Cause Analysis

Kestrel's investigation summary:

> *"The pod anti-affinity rule in the payments-api Deployment caused scheduling failures due to restrictive affinity preferences combined with a small 4-node cluster."*

### Generated Fix

Kestrel generates a strategic merge patch (`payments-api-deployment-fix.yaml`) that can be applied directly:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
spec:
  template:
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: payments-api
                topologyKey: kubernetes.io/hostname
```

This changes from `required` to `preferred` anti-affinity, allowing pods to schedule on the same node when necessary while still preferring spread when capacity allows.

## Files

- `main.tf` - EKS cluster, node group, deployment with anti-affinity
- `outputs.tf` - Useful commands and fix instructions
- `variables.tf` - Region configuration
- `scripts/run_demo.sh` - Automated demo runner
- `scripts/generate_load.sh` - Load generator for HPA testing
- `scripts/apply_fix.sh` - Applies the anti-affinity fix
- `scripts/show_status.sh` - Shows current cluster status

## License

MIT
