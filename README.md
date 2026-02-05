# Kestrel AI Demos

This repository contains demonstration infrastructure configurations for showcasing Kestrel AI's cloud incident response capabilities.

## Available Demos

### [VPC Peering Blackhole Demo](./vpc-peering-blackhole-demo/)

Demonstrates a common VPC peering misconfiguration where asymmetric routing causes network "blackholes" - traffic flows one way but responses cannot return.

### [MSK Broker Resource Constraint Demo](./msk-broker-constraint-demo/)

Demonstrates how undersized MSK brokers become resource-constrained under production load. Creates an MSK cluster with undersized brokers and generates high-volume traffic to trigger CPU and memory exhaustion.

### [MSK Cluster Capacity Demo](./msk-capacity-demo/)

Demonstrates how an undersized 2-broker MSK cluster becomes capacity-bound under high throughput, causing under-replicated partitions. Kestrel detects this and generates a two-step fix: adding brokers via AWS API and rebalancing partitions via Kafka CLI.

### [EKS Pod Anti-Affinity Scheduling Demo](./eks-anti-affinity-demo/)

Demonstrates how required pod anti-affinity causes scheduling failures when scaling beyond available nodes. Works fine in dev/staging with few replicas, but fails in production when HPA tries to scale during traffic spikes. Shows the classic "works in dev, breaks in prod" scenario.

### [MIG Fragmentation Demo](./mig-fragmentation-demo/)

Demonstrates GPU resource fragmentation on Kubernetes clusters running NVIDIA A100/H100 GPUs with Multi-Instance GPU (MIG) enabled. MIG instances must be created from contiguous GPU slices, which leads to fragmentation over time. Your dashboard shows 40GB "available" but training jobs requesting `2g.10gb` stay Pending because no GPU has 2 contiguous slices free. Kestrel detects this invisible problem and shows exactly how to fix it.

## License

MIT
