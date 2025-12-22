# MSK Broker Resource Constraint Demo

This Terraform configuration demonstrates how undersized MSK brokers become resource-constrained under production load. It's a common real-world scenario that [Kestrel AI](https://usekestrel.ai) detects and remediates automatically.

## The Scenario

Kafka clusters are often initially provisioned based on estimated load, but actual production traffic frequently exceeds those estimates. This demo creates an MSK cluster with intentionally undersized `t3.small` brokers (2GB RAM) and generates high-volume traffic to trigger resource constraints.

**What happens:**
- Brokers start healthy with low CPU/memory usage
- Under sustained load, CPU climbs to 70-90% and memory exceeds 90%
- Latency increases, ISR shrink events occur
- Without intervention: producer timeouts, consumer lag, potential outage

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    MSK BROKER RESOURCE CONSTRAINT DEMO                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  VPC (10.0.0.0/16)                                                      │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐             │
│  │   Subnet 1     │  │   Subnet 2     │  │   Subnet 3     │             │
│  │   (AZ-a)       │  │   (AZ-b)       │  │   (AZ-c)       │             │
│  │                │  │                │  │                │             │
│  │  ┌──────────┐  │  │  ┌──────────┐  │  │  ┌──────────┐  │             │
│  │  │ Broker 1 │  │  │  │ Broker 2 │  │  │  │ Broker 3 │  │             │
│  │  │ t3.small │  │  │  │ t3.small │  │  │  │ t3.small │  │             │
│  │  │ 2GB RAM  │  │  │  │ 2GB RAM  │  │  │  │ 2GB RAM  │  │             │
│  │  └──────────┘  │  │  └──────────┘  │  │  └──────────┘  │             │
│  └───────┬────────┘  └───────┬────────┘  └───────┬────────┘             │
│          │                   │                   │                      │
│          └───────────────────┴───────────────────┘                      │
│                              │                                          │
│                    ┌─────────┴─────────┐                                │
│                    │  Client Instance  │                                │
│                    │  (Producer)       │                                │
│                    └───────────────────┘                                │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- AWS account with permissions for VPC, EC2, MSK, IAM, CloudWatch
- Terraform >= 1.5
- AWS CLI configured (`aws sts get-caller-identity` works)
- ~20 minutes for MSK cluster creation

## Resources Created

| Resource | Purpose |
|----------|---------|
| VPC + 3 Subnets | Network infrastructure across 3 AZs |
| MSK Cluster (3 brokers) | Kafka cluster with t3.small instances |
| EC2 Instance | Client for running producer scripts |
| CloudWatch Alarms | Alerts for CPU and memory thresholds |
| IAM Roles | For SSM access and MSK permissions |

**Estimated Cost:** ~$0.50/hour (mostly MSK brokers)

## Quick Start

### 1. Deploy the Infrastructure

```bash
cd msk-broker-constraint-demo
terraform init
terraform apply -auto-approve
```

> ☕ MSK takes ~15-20 minutes to provision.

### 2. Connect to the Client Instance

```bash
CLIENT_ID=$(terraform output -raw client_instance_id)
aws ssm start-session --target $CLIENT_ID
```

### 3. Set Up the Environment

Once connected:

```bash
export BOOTSTRAP=$(aws kafka get-bootstrap-brokers \
  --cluster-arn $(aws kafka list-clusters --query 'ClusterInfoList[?ClusterName==`msk-demo-*`].ClusterArn' --output text) \
  --query 'BootstrapBrokerString' --output text)

echo "Bootstrap servers: $BOOTSTRAP"
```

### 4. Create a Topic

```bash
/opt/kafka/bin/kafka-topics.sh --create \
  --topic stress-demo \
  --partitions 6 \
  --replication-factor 2 \
  --bootstrap-server $BOOTSTRAP
```

### 5. Generate Load

```bash
python3 /home/ec2-user/scripts/hotspot_producer.py \
  --bootstrap-servers $BOOTSTRAP \
  --topic stress-demo \
  --rate 500 \
  --duration 600
```

## What to Observe

After a few minutes of sustained load, check CloudWatch metrics:

- **CpuUser** per broker: climbing to 70-90%
- **MemoryUsed** per broker: exceeding 90%
- **ProduceLocalTimeMsMean**: increasing latency

These are the early warning signs of broker resource exhaustion.

## The Fix

### AWS CLI

```bash
aws kafka update-broker-type \
  --cluster-arn <CLUSTER_ARN> \
  --target-instance-type kafka.m5.large \
  --current-version <CURRENT_VERSION>
```

### Terraform

```hcl
# Before (undersized)
resource "aws_msk_cluster" "demo" {
  broker_node_group_info {
    instance_type = "kafka.t3.small"  # 2GB RAM
  }
}

# After (right-sized)
resource "aws_msk_cluster" "demo" {
  broker_node_group_info {
    instance_type = "kafka.m5.large"  # 8GB RAM
  }
}
```

## Cleanup

```bash
terraform destroy -auto-approve
```

> MSK deletion takes ~15 minutes.

## How Kestrel Helps

[Kestrel AI](https://usekestrel.ai) monitors your MSK clusters and detects resource constraints before they become outages:

- **Early Detection:** Identifies when brokers exceed CPU/memory thresholds
- **Root Cause Analysis:** Correlates resource metrics with broker instance types
- **Automated Remediation:** Generates the exact AWS CLI command or Terraform fix to right-size the cluster

[Sign up for a free trial](https://platform.usekestrel.ai/register) to see Kestrel detect this scenario in real-time.

## License

MIT
