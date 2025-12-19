# VPC Peering Blackhole Demo

This Terraform configuration creates a VPC peering setup that demonstrates a common routing misconfiguration - a "blackhole" where traffic can flow in one direction but responses cannot return.

## What It Creates

- **VPC A** (10.10.0.0/16) with two subnets:
  - Subnet A1: 10.10.1.0/24
  - Subnet A2: 10.10.2.0/24
- **VPC B** (10.20.0.0/16) with one subnet:
  - Subnet B: 10.20.1.0/24
- **VPC Peering Connection** between VPC A and VPC B
- **EC2 Instances** in each subnet with SSM access for testing
- **VPC Flow Logs** for both VPCs

## The Misconfiguration

VPC B's route table is **intentionally misconfigured** to only route back to `10.10.1.0/24` (Subnet A1), **missing** `10.10.2.0/24` (Subnet A2).

This means:
- ✅ Traffic from Subnet A1 → VPC B works (responses can return)
- ❌ Traffic from Subnet A2 → VPC B times out (responses are dropped - "blackhole")

## Usage

```bash
# Initialize
terraform init

# Apply
terraform apply

# Get outputs
terraform output

# Clean up
terraform destroy
```

## Requirements

- Terraform >= 1.0
- AWS credentials with VPC, EC2, IAM, and CloudWatch Logs permissions
- AWS region: us-west-1 (configurable)

## Testing the Blackhole

After applying, use SSM to connect to the instances and test connectivity:

```bash
# From client-ok (Subnet A1) - should work
curl http://<server_private_ip>:8080

# From client-broken (Subnet A2) - will timeout
curl http://<server_private_ip>:8080
```
