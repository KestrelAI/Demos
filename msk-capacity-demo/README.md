# MSK Cluster Capacity Demo

This demo shows how Kestrel detects when an MSK cluster doesn't have enough brokers to handle the workload, and generates a **two-step fix**:
1. **AWS CLI**: Add brokers to the cluster
2. **Kafka CLI**: Rebalance partitions across all brokers (including new ones)

## The Problem

A 2-broker MSK cluster (the minimum) is easily overwhelmed under heavy load. When brokers can't keep up with replication, partitions become "under-replicated" - meaning not all replicas are in sync.

**Important**: Simply adding brokers via AWS CLI doesn't fully solve the problem! Kafka doesn't automatically move existing partitions to new brokers. You must run `kafka-reassign-partitions.sh` to distribute load evenly.

## The Two-Step Fix

### Step 1: Add Brokers

Kestrel generates this fix in multiple formats depending on your workflow:

**AWS CLI** (for quick execution):
```bash
aws kafka update-broker-count \
  --cluster-arn <cluster-arn> \
  --current-version <version> \
  --target-number-of-broker-nodes 4
```

**Terraform** (for IaC workflows):
```hcl
resource "aws_msk_cluster" "demo" {
  # ...
- number_of_broker_nodes = 2
+ number_of_broker_nodes = 4
  # ...
}
```

Kestrel integrates with IaC tools including **Terraform** and **Pulumi**, allowing you to apply fixes through your existing infrastructure-as-code pipelines.

This adds new brokers to the cluster, but existing partitions remain on the original brokers.

### Step 2: Rebalance Partitions (Kafka CLI via SSM)

After brokers are added, partitions must be redistributed:

```bash
# Generate reassignment plan
/opt/kafka/bin/kafka-reassign-partitions.sh \
  --bootstrap-server <bootstrap-servers> \
  --topics-to-move-json-file /tmp/topics.json \
  --broker-list 1,2,3,4 \
  --generate

# Execute reassignment
/opt/kafka/bin/kafka-reassign-partitions.sh \
  --bootstrap-server <bootstrap-servers> \
  --reassignment-json-file /tmp/reassignment.json \
  --execute

# Verify completion
/opt/kafka/bin/kafka-reassign-partitions.sh \
  --bootstrap-server <bootstrap-servers> \
  --reassignment-json-file /tmp/reassignment.json \
  --verify
```

Kestrel generates both fixes and can execute them via "Apply Fix" - the Kafka CLI commands are run via SSM on the EC2 client instance.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                    MSK Cluster (2 Brokers - Undersized!)                 │
│  ┌─────────────────────────┐      ┌─────────────────────────┐            │
│  │        Broker 1         │◄────►│        Broker 2         │            │
│  │    (kafka.t3.small)     │  REP │    (kafka.t3.small)     │            │
│  │   CPU: 🔥 80%+          │      │   CPU: 🔥 80%+           │            │
│  │   Leader: P0,P2,P4      │      │   Leader: P1,P3,P5      │            │
│  │   Replica: P1,P3,P5     │      │   Replica: P0,P2,P4     │            │
│  └──────────▲──────────────┘      └──────────▲──────────────┘            │
│             │                                │                           │
│             └────────────┬───────────────────┘                           │
│                          │                                               │
└──────────────────────────┼───────────────────────────────────────────────┘
                           │
              ┌────────────┴────────────┐
              │     EC2 (c5.9xlarge)    │
              │   Go Stress Producer    │
              │   64 goroutines         │
              │   acks=all, LZ4         │
              │   10KB msgs, 1MB batch  │
              │                         │
              │   + Kafka CLI for fixes │
              └─────────────────────────┘

When load exceeds cluster capacity:
1. Replication falls behind
2. UnderReplicatedPartitions > 0
3. Kestrel detects: MSKClusterCapacityInsufficient
4. Fix Step 1: Add brokers (aws kafka update-broker-count)
5. Fix Step 2: Rebalance (kafka-reassign-partitions.sh via SSM)
```

## Running the Demo

### 1. Deploy Infrastructure (~20 minutes)

```bash
cd msk-capacity-demo
terraform init
terraform apply -auto-approve
```

This creates:
- 2-broker MSK cluster (kafka.t3.small)
- EC2 client instance (c5.9xlarge with 36 vCPUs)
- Go 1.21 and Kafka CLI installed on EC2

### 2. Run the Stress Test

```bash
./scripts/run_demo.sh
```

The script:
1. Uploads and builds the Go stress producer on EC2
2. Creates a test topic with 12 partitions
3. Runs 64 parallel producer goroutines with optimized settings:
   - 10KB messages with LZ4 compression
   - 1MB batch size, 10ms linger
   - `acks=all` (wait for all replicas)
4. Monitors `UnderReplicatedPartitions` metric
5. Shows the two-step fix when partitions become under-replicated

### 3. Connect to EC2 for Manual Testing

```bash
./scripts/run_demo.sh --interactive
```

Then on EC2:
```bash
# Set bootstrap servers
export BOOTSTRAP=$(terraform output -raw bootstrap_brokers)

# Run the Go producer manually
cd /home/ec2-user/demo
./stress_producer -bootstrap $BOOTSTRAP -topic stress-test -duration 300 -workers 64
```

### 4. Observe in Kestrel

Kestrel will detect:
- **Incident Type:** `MSKClusterCapacityInsufficient`
- **Severity:** High
- **Signal:** `UnderReplicatedPartitions > 0`
- **Recommended Fixes:**
  1. Add brokers via `update-broker-count`
  2. Rebalance partitions via `kafka-reassign-partitions.sh` (executed via SSM)

## Producer Optimization Settings

The Go producer is optimized for maximum throughput:

| Setting | Value | Purpose |
|---------|-------|---------|
| `workers` | 64 | Match vCPU count for parallelism |
| `msg-size` | 10KB | Larger messages = more data per request |
| `batch-size` | 1MB | Larger batches = fewer requests |
| `linger-ms` | 10 | Wait to fill batches |
| `compression` | LZ4 | Good compression + speed |
| `acks` | all | Maximum broker load (wait for all replicas) |

## Why This Works

With only 2 brokers and `replication.factor=2`:
- Every partition must have replicas on BOTH brokers
- Any slowdown on either broker causes replication lag
- Heavy load + `acks=all` means producers wait for both replicas
- System becomes bottlenecked quickly

The Go producer with 64 goroutines can push ~50-100 MB/sec of data, which is enough to stress the small t3.small brokers.

## Cleanup

```bash
terraform destroy -auto-approve
```

## Files

- `main.tf` - Terraform configuration
- `outputs.tf` - Output values including fix commands
- `scripts/stress_producer.go` - High-performance Go producer
- `scripts/go.mod` - Go module dependencies
- `scripts/run_demo.sh` - Demo orchestration script
- `scripts/broker_monitor.py` - CloudWatch metrics monitor


