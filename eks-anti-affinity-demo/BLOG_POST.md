# How Kestrel Detects & Fixes Kubernetes Scheduling Failures Before Your Pager Goes Off

A deep dive into how Kestrel automatically identifies and remediates complex Kubernetes misconfigurations in organizations where everyone may not understand Kubernetes.

---

Be me. A 25 year old software engineer who has worked for small and large organizations. Some were monorepo based using Docker Swarm, others still running on physical servers in the basement. Then I got a new job. The entire stack was Kubernetes. I had never once attempted to learn how Kubernetes worked and here I was expected to create and modify base Helm charts for the new "micro" services I was told to build.

I am not the only engineer who has been in this position.

But being in this position brings real risk to organizations. Asking ChatGPT for a template Helm chart without reading too much of it is a real thing that happens. Copying the "production-hardened" manifest from another team's service without understanding why those settings exist. Adding configurations that sound like good ideas on paper.

And then months later, something breaks. In production. During a traffic spike. And nobody remembers who added that YAML block or why.

## The Scenario: Anti-Affinity Done Wrong

Here's a story that plays out constantly in organizations running Kubernetes.

A platform team reviews a new payments service before it goes to production. They add pod anti-affinity to make it more resilient:

> "If a node goes down, we don't want to lose multiple payment pods at once. Let's make sure each pod runs on a different node."

Makes sense. They add this to the deployment:

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: payments-api
        topologyKey: kubernetes.io/hostname
```

They use `required` instead of `preferred` because stricter is safer, right?

The service deploys to staging. QA runs their test suite. Product signs off. Everything looks good. The service goes to production with 4 replicas across 4 nodes. It runs perfectly for weeks.

Then Black Friday hits.

Traffic spikes. The Horizontal Pod Autoscaler kicks in and tries to scale from 4 replicas to 8. But there are only 4 nodes in the cluster.

```
$ kubectl get pods -n payments
NAME                           READY   STATUS    AGE
payments-api-7d4f8b6c9-abc12   1/1     Running   45d
payments-api-7d4f8b6c9-def34   1/1     Running   45d
payments-api-7d4f8b6c9-ghi56   1/1     Running   45d
payments-api-7d4f8b6c9-jkl78   1/1     Running   45d
payments-api-7d4f8b6c9-mno90   0/1     Pending   2m    # Stuck
payments-api-7d4f8b6c9-pqr12   0/1     Pending   2m    # Stuck
payments-api-7d4f8b6c9-stu34   0/1     Pending   2m    # Stuck
payments-api-7d4f8b6c9-vwx56   0/1     Pending   2m    # Stuck
```

Four pods are stuck Pending. The service can't handle the load. Checkout latency spikes. Customers abandon carts. The on-call engineer gets paged.

The event log shows:

```
0/4 nodes are available: 4 node(s) didn't match pod anti-affinity rules.
```

The irony? The anti-affinity was added to *improve* resilience. Instead, it caused an outage during the exact high-stakes moment it was supposed to protect against.

## Why This Works in Dev but Breaks in Prod

This is the classic "works on my machine" problem, but for infrastructure.

| Environment | Replicas | Nodes | Result |
|-------------|----------|-------|--------|
| Dev | 2 | 5 | Works fine |
| Staging | 3 | 5 | Works fine |
| Prod (normal) | 4 | 4 | Works fine |
| Prod (traffic spike) | 8 | 4 | **4 pods stuck Pending** |

In dev and staging, you never hit the constraint because you have more nodes than pods. The misconfiguration sits there silently, waiting for the one scenario that will trigger it: scaling beyond your node count.

Nobody tests for this. Load testing might catch the memory leak or the slow database query, but it won't catch the scheduling constraint that only matters when the HPA tries to add more replicas than you have nodes.

## Demo Setup

We've created an open-source Terraform configuration that demonstrates this exact scenario. You can find it on GitHub:

[KestrelAI/Demos - EKS Anti-Affinity Demo](https://github.com/KestrelAI/Demos/tree/main/eks-anti-affinity-demo)

Clone the repo and follow along with your own AWS account.

## Architecture Overview

The demo creates an EKS cluster with a fixed-size node pool:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    EKS Cluster (4 nodes - fixed size)                   │
│                                                                         │
│   ┌───────────────┐  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐
│   │    Node 1     │  │    Node 2     │  │    Node 3     │  │    Node 4     │
│   │ ┌───────────┐ │  │ ┌───────────┐ │  │ ┌───────────┐ │  │ ┌───────────┐ │
│   │ │  pod-1    │ │  │ │  pod-2    │ │  │ │  pod-3    │ │  │ │  pod-4    │ │
│   │ │  Running  │ │  │ │  Running  │ │  │ │  Running  │ │  │ │  Running  │ │
│   │ └───────────┘ │  │ └───────────┘ │  │ └───────────┘ │  │ └───────────┘ │
│   └───────────────┘  └───────────────┘  └───────────────┘  └───────────────┘
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

The deployment has an HPA configured to scale up to 8 replicas, but the node pool is fixed at 4. Combined with the `required` anti-affinity rule, this guarantees that scaling beyond 4 pods will fail.

## The Misconfiguration

Here's the problematic configuration from the Terraform (in `main.tf`):

```hcl
spec {
  affinity {
    pod_anti_affinity {
      # THE PROBLEM: "required" means pods MUST be on different nodes
      # If there aren't enough nodes, pods stay Pending forever
      required_during_scheduling_ignored_during_execution {
        label_selector {
          match_labels = {
            app = "payments-api"
          }
        }
        topology_key = "kubernetes.io/hostname"
      }
    }
  }
}
```

The `required_during_scheduling_ignored_during_execution` constraint tells Kubernetes: "Each pod of this deployment MUST run on a different node. If you can't satisfy this, don't schedule the pod at all."

With 4 nodes and a request for 8 pods, Kubernetes will schedule 4 and leave 4 stuck in Pending. Forever.

## Testing the Setup

After deploying the Terraform (~15-20 minutes for EKS), you can reproduce the issue:

### 1. Configure kubectl

```bash
$(terraform output -raw kubeconfig_command)
```

### 2. Check Initial State

```bash
$ kubectl get pods -n payments
NAME                           READY   STATUS    AGE
payments-api-7d4f8b6c9-abc12   1/1     Running   5m
payments-api-7d4f8b6c9-def34   1/1     Running   5m
```

Two pods, running fine. Everything looks good.

### 3. Trigger the Issue

```bash
$ kubectl scale deployment payments-api -n payments --replicas=8
deployment.apps/payments-api scaled

$ kubectl get pods -n payments
NAME                           READY   STATUS    AGE
payments-api-7d4f8b6c9-abc12   1/1     Running   6m
payments-api-7d4f8b6c9-def34   1/1     Running   6m
payments-api-7d4f8b6c9-ghi56   1/1     Running   30s
payments-api-7d4f8b6c9-jkl78   1/1     Running   30s
payments-api-7d4f8b6c9-mno90   0/1     Pending   30s
payments-api-7d4f8b6c9-pqr12   0/1     Pending   30s
payments-api-7d4f8b6c9-stu34   0/1     Pending   30s
payments-api-7d4f8b6c9-vwx56   0/1     Pending   30s
```

Four pods scheduled (one per node), four stuck Pending.

### 4. See Why They're Pending

```bash
$ kubectl get events -n payments --field-selector reason=FailedScheduling
LAST SEEN   TYPE      REASON             MESSAGE
30s         Warning   FailedScheduling   0/4 nodes are available: 4 node(s)
                                         didn't match pod anti-affinity rules.
```

## How Kestrel Detects and Fixes This

With Kestrel connected to your cluster, this misconfiguration is detected as soon as pods enter the Pending state.

Kestrel observes the scheduling failure events and correlates them with the deployment's affinity configuration. It identifies that the `requiredDuringSchedulingIgnoredDuringExecution` anti-affinity rule is preventing pod scheduling because the number of desired replicas exceeds available nodes.

```
⚠️ Pod Scheduling Deadlock Detected

Deployment payments-api in namespace payments has 4 pods stuck in Pending state.
The deployment uses requiredDuringSchedulingIgnoredDuringExecution pod anti-affinity
with topologyKey kubernetes.io/hostname, but the HPA maxReplicas (8) exceeds the
available node count (4). Pods beyond 4 replicas will never be scheduled.

Affected pods: payments-api-mno90, payments-api-pqr12, payments-api-stu34, payments-api-vwx56
```

Once identified, Kestrel generates the exact fix. That fix can be applied immediately via kubectl, or as a pull request against your Helm chart or GitOps repository.

### kubectl Patch

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

### Helm Chart Fix

```yaml
# Before (causes scheduling deadlock)
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: payments-api
        topologyKey: kubernetes.io/hostname

# After (flexible scheduling)
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

The difference is subtle but critical. `preferred` tells Kubernetes: "Try to put pods on different nodes, but if you can't, schedule them anyway." You still get the resilience benefits when capacity allows, but you don't block scaling when it matters most.

## Why This Matters

Pod anti-affinity misconfigurations are surprisingly common:

**The Knowledge Gap** – Application engineers adding Kubernetes manifests often don't understand the difference between `required` and `preferred` affinity. The names sound similar, but the behavior is drastically different.

**The Copy-Paste Problem** – Teams copy configurations from other services or Stack Overflow without understanding the implications. A config that works for a 3-replica service with 10 nodes might deadlock a different service.

**The "Hardening" Trap** – Platform teams add strict anti-affinity to improve resilience, not realizing they've created a scaling ceiling. The stricter setting feels safer, but it's actually more brittle.

**The Silent Failure** – The misconfiguration doesn't manifest until you try to scale beyond your node count. In dev and staging, you never hit that limit. The first time you see it is during a production traffic spike, which is the worst possible time.

## Try It Yourself

Want to see Kestrel detect and resolve this in real-time? Here's how:

1. Clone the demo repository:
```bash
git clone https://github.com/KestrelAI/Demos.git
```

2. [Sign up for a free trial](https://platform.usekestrel.ai/register) and connect your AWS account

3. Deploy the EKS cluster:
```bash
cd Demos/eks-anti-affinity-demo
terraform init
terraform apply
```

4. Run the demo script:
```bash
./scripts/run_demo.sh
```

5. Watch Kestrel detect the scheduling failure and generate the fix in real-time.

---

The engineer who added that anti-affinity rule wasn't wrong to want resilience. They just didn't know there was a better way to express that intent. And in a world where application engineers are expected to write Kubernetes manifests without deep K8s expertise, that's going to keep happening.

Kestrel catches these misconfigurations before they become 2 AM pages. Not by replacing your team's judgment, but by having the Kubernetes knowledge that not everyone on your team has time to acquire.
