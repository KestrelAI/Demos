#!/bin/bash
# =============================================================================
# MSK Cluster Capacity Demo - High Throughput Version
# =============================================================================
# Overwhelms a 2-broker cluster to cause under-replicated partitions.
# Uses a high-performance Go producer to maximize broker CPU utilization.
#
# Kestrel detects this and recommends:
# 1. Adding brokers (aws kafka update-broker-count)
# 2. Rebalancing partitions (kafka-reassign-partitions.sh)
# =============================================================================

set -e

# Settings for stress test - stay under MSK 1MB message limit
DURATION=600          # 10 minutes
WORKERS=64            # Goroutines  
MSG_SIZE=1024         # 1KB messages (smaller = more messages, under limit)
BATCH_SIZE=102400     # 100KB batches (well under 1MB limit)
LINGER_MS=5          
COMPRESSION="none"    # No compression for predictable size
TOPIC="stress-test"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "  -d, --duration    Duration in seconds (default: 300)"
    echo "  -w, --workers     Number of producer goroutines (default: 64)"
    echo "  -s, --msg-size    Message size in bytes (default: 10240)"
    echo "  --interactive     Open shell on EC2"
    echo "  --python          Use Python producer instead of Go"
}

INTERACTIVE=false
USE_PYTHON=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--duration)  DURATION="$2"; shift 2 ;;
        -w|--workers)   WORKERS="$2"; shift 2 ;;
        -s|--msg-size)  MSG_SIZE="$2"; shift 2 ;;
        --interactive)  INTERACTIVE=true; shift ;;
        --python)       USE_PYTHON=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              log_error "Unknown: $1"; exit 1 ;;
    esac
done

echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║              MSK Cluster Capacity Demo (High Throughput)           ║"
echo "║           Stress test 2-broker cluster with Go producer            ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

log_info "Reading Terraform outputs..."
cd "$TF_DIR"

INSTANCE_ID=$(terraform output -raw client_instance_id 2>/dev/null || true)
BOOTSTRAP=$(terraform output -raw bootstrap_brokers 2>/dev/null || true)
CLUSTER_NAME=$(terraform output -raw msk_cluster_name 2>/dev/null || true)
CLUSTER_ARN=$(terraform output -raw cluster_arn 2>/dev/null || true)
NUM_BROKERS=$(terraform output -raw number_of_brokers 2>/dev/null || echo "2")

AWS_REGION=$(echo "$BOOTSTRAP" | grep -oE '[a-z]+-[a-z]+-[0-9]+' | head -1)
[ -z "$AWS_REGION" ] && AWS_REGION="us-west-2"

if [ -z "$INSTANCE_ID" ] || [ -z "$BOOTSTRAP" ]; then
    log_error "Terraform outputs not found. Run 'terraform apply' first."
    exit 1
fi

log_success "Cluster: $CLUSTER_NAME"
log_success "Brokers: $NUM_BROKERS (undersized for high throughput!)"
log_success "Instance: $INSTANCE_ID"
log_success "Region: $AWS_REGION"
echo ""

if [ "$INTERACTIVE" = true ]; then
    exec aws ssm start-session --target "$INSTANCE_ID" --region "$AWS_REGION"
fi

# Upload and build Go producer
log_info "Uploading and building Go stress producer..."

# Base64 encode the Go source files
GO_MAIN_B64=$(base64 < "$SCRIPT_DIR/stress_producer.go")
GO_MOD_B64=$(base64 < "$SCRIPT_DIR/go.mod")

UPLOAD_CMD="mkdir -p /home/ec2-user/demo && cd /home/ec2-user/demo && echo $GO_MOD_B64 | base64 -d > go.mod && echo $GO_MAIN_B64 | base64 -d > stress_producer.go"

aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"$UPLOAD_CMD\"]" \
    --timeout-seconds 60 \
    --region "$AWS_REGION" \
    --output text > /dev/null 2>&1

sleep 3

# Build the Go producer (use full path since SSM doesn't source profile.d)
log_info "Building Go producer on EC2 (this may take a minute on first run)..."
BUILD_CMD="cd /home/ec2-user/demo && export HOME=/home/ec2-user && export PATH=\$PATH:/usr/local/go/bin && export GOPATH=/home/ec2-user/go && export GOCACHE=/home/ec2-user/.cache/go-build && go mod tidy && go build -o stress_producer stress_producer.go 2>&1"

CMD_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"$BUILD_CMD\"]" \
    --timeout-seconds 180 \
    --region "$AWS_REGION" \
    --query "Command.CommandId" \
    --output text)

# Wait for build to complete
sleep 5
for i in {1..30}; do
    STATUS=$(aws ssm get-command-invocation \
        --command-id "$CMD_ID" \
        --instance-id "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query "Status" \
        --output text 2>/dev/null || echo "Pending")
    
    if [ "$STATUS" = "Success" ]; then
        log_success "Go producer built successfully"
        break
    elif [ "$STATUS" = "Failed" ]; then
        log_error "Build failed. Checking logs..."
        aws ssm get-command-invocation \
            --command-id "$CMD_ID" \
            --instance-id "$INSTANCE_ID" \
            --region "$AWS_REGION" \
            --query "StandardOutputContent" \
            --output text
        exit 1
    fi
    sleep 3
done

# Create the topic (if not exists)
log_info "Creating stress test topic..."
CREATE_CMD="/opt/kafka/bin/kafka-topics.sh --create --topic $TOPIC --partitions 12 --replication-factor 2 --bootstrap-server $BOOTSTRAP --if-not-exists 2>/dev/null || true"

aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"$CREATE_CMD\"]" \
    --timeout-seconds 30 \
    --region "$AWS_REGION" \
    --output text > /dev/null 2>&1

sleep 3
log_success "Topic ready"
echo ""

# Run stress test
log_info "Starting stress test..."
echo ""
echo "  Workers:      $WORKERS goroutines"
echo "  Message size: $MSG_SIZE bytes"
echo "  Batch size:   $BATCH_SIZE bytes"
echo "  Compression:  $COMPRESSION"
echo "  Duration:     ${DURATION}s"
echo ""
log_warn "Target: Push high throughput to cause under-replicated partitions"
echo ""

# Single producer - simpler and easier to debug
REMOTE_CMD="cd /home/ec2-user/demo && ./stress_producer -bootstrap $BOOTSTRAP -topic $TOPIC -duration $DURATION -workers $WORKERS -size $MSG_SIZE -batch-size $BATCH_SIZE -linger-ms $LINGER_MS -compression $COMPRESSION 2>&1"

CMD_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"$REMOTE_CMD\"]" \
    --timeout-seconds $((DURATION + 300)) \
    --region "$AWS_REGION" \
    --query "Command.CommandId" \
    --output text)

log_success "Stress test started (ID: $CMD_ID)"
echo ""

# Wait and check producer output
sleep 15
log_info "Checking producer output..."
for i in 1 2 3; do
    STARTUP_OUTPUT=$(aws ssm get-command-invocation \
        --command-id "$CMD_ID" \
        --instance-id "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query "StandardOutputContent" \
        --output text 2>/dev/null || echo "")
    STARTUP_ERR=$(aws ssm get-command-invocation \
        --command-id "$CMD_ID" \
        --instance-id "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query "StandardErrorContent" \
        --output text 2>/dev/null || echo "")
    STATUS=$(aws ssm get-command-invocation \
        --command-id "$CMD_ID" \
        --instance-id "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query "Status" \
        --output text 2>/dev/null || echo "Unknown")
    
    echo "  Status: $STATUS"
    if [ -n "$STARTUP_OUTPUT" ]; then
        echo "  Output:"
        echo "$STARTUP_OUTPUT" | head -30 | sed 's/^/    /'
    fi
    if [ -n "$STARTUP_ERR" ]; then
        echo "  Errors:"
        echo "$STARTUP_ERR" | head -10 | sed 's/^/    /'
    fi
    
    if [ "$STATUS" = "Success" ] || [ "$STATUS" = "Failed" ]; then
        break
    fi
    sleep 10
done
echo ""

# Run monitor in parallel
log_info "Starting cluster capacity monitor..."
log_warn "Watch for: UnderReplicatedPartitions > 0"
echo ""

python3 "$SCRIPT_DIR/broker_monitor.py" "$CLUSTER_NAME" "$AWS_REGION" "$DURATION" "$NUM_BROKERS"

# Get stress test output
log_info "Getting stress test results..."
sleep 5

OUTPUT=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query "StandardOutputContent" \
    --output text 2>/dev/null || echo "Still running...")

echo ""
echo "$OUTPUT"

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "DEMO SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "If UnderReplicatedPartitions > 0 with high CPU across all brokers:"
echo "→ Cluster is capacity-bound. Kestrel will recommend a 2-step fix:"
echo ""
echo "STEP 1: Add brokers (AWS CLI)"
echo ""
terraform output -raw add_broker_command 2>/dev/null || \
cat << EOFCMD
aws kafka update-broker-count \\
  --cluster-arn $CLUSTER_ARN \\
  --target-number-of-broker-nodes 4 \\
  --current-version \$(aws kafka describe-cluster --cluster-arn $CLUSTER_ARN --query 'ClusterInfo.CurrentVersion' --output text)
EOFCMD
echo ""
echo "STEP 2: Rebalance partitions (Kafka CLI via SSM)"
echo ""
echo "# Generate reassignment plan"
echo "/opt/kafka/bin/kafka-reassign-partitions.sh \\"
echo "  --bootstrap-server $BOOTSTRAP \\"
echo "  --topics-to-move-json-file topics.json \\"
echo "  --broker-list '1,2,3,4' \\"
echo "  --generate"
echo ""
echo "# Execute reassignment"
echo "/opt/kafka/bin/kafka-reassign-partitions.sh \\"
echo "  --bootstrap-server $BOOTSTRAP \\"
echo "  --reassignment-json-file reassignment.json \\"
echo "  --execute"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_success "Demo complete!"

