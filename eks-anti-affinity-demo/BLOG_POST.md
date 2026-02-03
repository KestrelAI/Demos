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
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app: payments-api
          topologyKey: kubernetes.io/hostname
```

They set `weight: 100` - the maximum value - because stronger preferences are better, right? The service should *really* want to spread across nodes.

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
FailedScheduling

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

The deployment has an HPA configured to scale up to 8 replicas, but the node pool is fixed at 4. Combined with the maximum-weight anti-affinity preference, the scheduler treats pod spreading as nearly mandatory - causing scaling failures when nodes run out.

## The Misconfiguration

Here's the problematic configuration in the Deployment manifest:

```yaml
spec:
  template:
    spec:
      affinity:
        podAntiAffinity:
          # THE PROBLEM: weight 100 makes this preference nearly mandatory
          # On a small cluster, this blocks scheduling when nodes fill up
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100  # Maximum weight - treated almost like "required"
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: payments-api
                topologyKey: kubernetes.io/hostname
```

The `weight: 100` setting is the maximum value. While technically a "preference," the scheduler treats high-weight preferences as near-mandatory constraints. It will exhaust all other scheduling options before violating this preference - and on a 4-node cluster, that means pods get stuck.

With 4 nodes and a request for 8 pods, Kubernetes will schedule 4 (one per node) and leave 4 stuck in Pending - because the scheduler won't co-locate pods on the same node when the anti-affinity weight is maxed out.

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

Kestrel observes the scheduling failure events and correlates them with the deployment's affinity configuration. It identifies that the high-weight `preferredDuringSchedulingIgnoredDuringExecution` anti-affinity rule is preventing pod scheduling because the weight is too restrictive for the cluster's node count.

### Root Cause Analysis

![Kestrel Root Cause Analysis](./screenshots/root-cause-analysis.png)
*Kestrel Root Cause Analysis showing the rollout failure incident*

Kestrel's investigation summary traces the chain of events:

1. **Deployment Created** - `payments-api` created with anti-affinity rules preferring pods to be scheduled on different nodes
2. **Pods Scheduled** - Initial pods successfully scheduled on 2 different nodes
3. **FailedScheduling Events** - When scaling beyond node count, scheduler reports `0/4 nodes are available: 4 node(s) didn't match pod anti-affinity rules`

The root cause is clear: *"The pod anti-affinity rule in the payments-api Deployment caused scheduling failures due to restrictive affinity preferences combined with a small 4-node cluster."*

### Resolution Recommendation

![Kestrel Resolution Recommendation](./screenshots/resolution-recommendation.png)
*Kestrel's recommended steps to resolve the incident*

Kestrel provides specific guidance:

1. Modify the Deployment's podAntiAffinity rule from `preferredDuringSchedulingIgnoredDuringExecution` to a less restrictive configuration, such as lowering the weight or removing the anti-affinity preference if spreading is not critical
2. Alternatively, add more nodes to the cluster to provide more scheduling options that satisfy the anti-affinity preference
3. Consider changing the anti-affinity rule to use `topologySpreadConstraints` with `whenUnsatisfiable: ScheduleAnyway` if strict pod separation is mandatory but cluster should continue to run pods even when constraints cannot be fully met
4. Monitor pod scheduling events after changes to ensure pods can be scheduled successfully
5. Implement alerting on FailedScheduling events to catch similar issues early

### The Remediation

![Kestrel Remediation YAML](./screenshots/remediation.png)
*Kestrel generates the exact YAML patch to fix the issue*

Kestrel generates a strategic merge patch that reduces the anti-affinity weight from 100 to 50:

```yaml
# payments-api-deployment-fix.yaml
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
            - weight: 50  # Reduced from 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: payments-api
                topologyKey: kubernetes.io/hostname
```

Apply it with:

```bash
kubectl apply -f payments-api-deployment-fix.yaml
```

This reduces the anti-affinity weight from 100 to 50, making the scheduling preference less restrictive. The scheduler will still *try* to spread pods across nodes, but with lower weight, it's more willing to co-locate pods on the same node when necessary.

The difference is subtle but critical. At `weight: 100`, the scheduler treats the preference as nearly mandatory. At `weight: 50`, it's a genuine preference - nice to have, but not worth blocking scaling. You still get the resilience benefits when capacity allows, but you don't block scaling when it matters most.

### Why weight 50?

The weight value (1-100) determines how strongly the scheduler prioritizes this preference relative to other scheduling factors. At 50, the scheduler still prefers spreading pods, but won't sacrifice scalability for it. This is the right trade-off for most production scenarios - you want distribution when possible, but you want your service to scale more than you want perfect distribution.

## Why This Matters

Pod anti-affinity misconfigurations are surprisingly common:

**The Knowledge Gap** – Application engineers adding Kubernetes manifests often don't understand how weight values affect scheduling behavior. Setting `weight: 100` seems like "maximum preference" but actually creates near-mandatory constraints.

**The Copy-Paste Problem** – Teams copy configurations from other services or Stack Overflow without understanding the implications. A config that works for a 3-replica service with 10 nodes might deadlock a different service with fewer nodes.

**The "Hardening" Trap** – Platform teams crank up anti-affinity weights to improve resilience, not realizing they've created a scaling ceiling. Higher weight feels safer, but it's actually more brittle.

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

The engineer who set that anti-affinity weight to 100 wasn't wrong to want resilience. They just didn't know that "maximum weight" would create a scaling ceiling. And in a world where application engineers are expected to write Kubernetes manifests without deep K8s expertise, that's going to keep happening.

Kestrel catches these misconfigurations before they become 2 AM pages. Not by replacing your team's judgment, but by having the Kubernetes knowledge that not everyone on your team has time to acquire.
