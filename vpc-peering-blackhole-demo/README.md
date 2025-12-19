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

## Requirements

- Terraform >= 1.0
- AWS CLI configured with credentials
- AWS credentials with VPC, EC2, IAM, and CloudWatch Logs permissions
- AWS region: us-west-1 (configurable)

## Usage

### 1. Deploy the Infrastructure

```bash
terraform init
terraform apply -auto-approve
```

### 2. Get the Server IP

```bash
SERVER_IP=$(terraform output -raw server_private_ip)
echo "Server IP: $SERVER_IP"
```

### 3. Test Client-OK (Should Succeed ✅)

```bash
CLIENT_OK=$(terraform output -raw client_ok_id)

CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --targets "Key=instanceids,Values=$CLIENT_OK" \
  --parameters "commands=curl -m 5 -s http://$SERVER_IP:8080" \
  --query "Command.CommandId" --output text)

# Wait for command to complete
sleep 5

# Get output
aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$CLIENT_OK" \
  --query "StandardOutputContent" --output text
```

**Expected output:** `hello from VPC B server`

### 4. Test Client-BROKEN (Should Timeout ❌)

```bash
CLIENT_BAD=$(terraform output -raw client_broken_id)

CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --targets "Key=instanceids,Values=$CLIENT_BAD" \
  --parameters "commands=curl -m 5 -v http://$SERVER_IP:8080 || echo TIMEOUT" \
  --query "Command.CommandId" --output text)

# Wait for timeout
sleep 10

# Get output
aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$CLIENT_BAD" \
  --query "StandardOutputContent" --output text
```

**Expected output:** `TIMEOUT` (or connection timeout errors)

### 5. Clean Up

```bash
terraform destroy -auto-approve
```

## Why This Happens

The blackhole occurs because:

1. **Client-BROKEN** (in Subnet A2: 10.10.2.0/24) sends a request to the server in VPC B
2. The request arrives at the server (forward path works via peering)
3. The server tries to send a response back to 10.10.2.x
4. VPC B's route table only has a route to 10.10.1.0/24, NOT 10.10.2.0/24
5. The response packet is dropped → **blackhole**

This is a common misconfiguration when setting up VPC peering with multiple subnets.
