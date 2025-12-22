#!/bin/bash
# =============================================================================
# MSK Broker Resource Constraint Demo
# =============================================================================
# Runs the MSK load test from your laptop by connecting to the EC2 client
# instance via AWS SSM.
#
# Usage:
#   ./run_demo.sh                    # Run with defaults (500 msg/s, 10 min)
#   ./run_demo.sh -r 1000 -d 300     # Custom rate and duration
#   ./run_demo.sh --interactive      # Open shell on the instance
#
# Prerequisites:
#   - AWS CLI configured with appropriate credentials
#   - Session Manager plugin: brew install session-manager-plugin
#   - Terraform applied in the parent directory
# =============================================================================

set -e

TOPIC="stress-demo"
RATE=500
DURATION=600
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -r, --rate        Messages per second (default: 500)"
    echo "  -d, --duration    Duration in seconds (default: 600)"
    echo "  -t, --topic       Kafka topic name (default: stress-demo)"
    echo "  --interactive     Open an interactive shell on the EC2 instance"
    echo "  -h, --help        Show this help message"
}

# Parse arguments
INTERACTIVE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--rate)      RATE="$2"; shift 2 ;;
        -d|--duration)  DURATION="$2"; shift 2 ;;
        -t|--topic)     TOPIC="$2"; shift 2 ;;
        --interactive)  INTERACTIVE=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║          MSK Broker Resource Constraint Demo               ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# Get Terraform outputs
# =============================================================================
log_info "Reading Terraform outputs..."
cd "$TF_DIR"

INSTANCE_ID=$(terraform output -raw client_instance_id 2>/dev/null || true)
BOOTSTRAP=$(terraform output -raw bootstrap_brokers 2>/dev/null || true)
CLUSTER_NAME=$(terraform output -raw msk_cluster_name 2>/dev/null || true)

# Get region from bootstrap servers (format: b-1.xxx.kafka.REGION.amazonaws.com)
AWS_REGION=$(echo "$BOOTSTRAP" | grep -oE '[a-z]+-[a-z]+-[0-9]+' | head -1)
if [ -z "$AWS_REGION" ]; then
    AWS_REGION="us-west-2"  # Default fallback
fi

if [ -z "$INSTANCE_ID" ] || [ -z "$BOOTSTRAP" ]; then
    log_error "Could not read Terraform outputs."
    log_error "Make sure you have run 'terraform apply' first."
    exit 1
fi

log_success "Cluster: $CLUSTER_NAME"
log_success "Instance: $INSTANCE_ID"
log_success "Region: $AWS_REGION"
echo ""

# =============================================================================
# Interactive mode
# =============================================================================
if [ "$INTERACTIVE" = true ]; then
    log_info "Opening interactive session..."
    log_info "Bootstrap servers: $BOOTSTRAP"
    echo ""
    echo "Once connected, run:"
    echo "  cd /home/ec2-user/demo"
    echo "  python3 stress_producer.py -b '$BOOTSTRAP' -t $TOPIC -r $RATE -d $DURATION"
    echo ""
    exec aws ssm start-session --target "$INSTANCE_ID" --region "$AWS_REGION"
fi

# =============================================================================
# Run the producer via SSM
# =============================================================================
log_info "Starting load test on EC2 instance..."
log_info "Topic: $TOPIC | Rate: $RATE msg/sec | Duration: ${DURATION}s"
echo ""

# Build the command to run on the instance
REMOTE_CMD="cd /home/ec2-user/demo && python3 stress_producer.py -b '$BOOTSTRAP' -t '$TOPIC' -r $RATE -d $DURATION"

# Send the command (fire and forget - we'll monitor via CloudWatch)
CMD_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters commands="[\"$REMOTE_CMD\"]" \
    --timeout-seconds $((DURATION + 180)) \
    --region "$AWS_REGION" \
    --query "Command.CommandId" \
    --output text)

log_success "Producer started (Command ID: $CMD_ID)"
echo ""

# =============================================================================
# Run the live broker monitor
# =============================================================================
log_info "Starting live broker metrics monitor..."
log_warn "Metrics may take 1-2 minutes to appear in CloudWatch"
echo ""

# Run the Python monitor script
python3 "$SCRIPT_DIR/broker_monitor.py" "$CLUSTER_NAME" "$AWS_REGION" "$DURATION"

echo ""

# Check if producer finished successfully
log_info "Checking producer status..."
RESPONSE=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --region "$AWS_REGION" 2>/dev/null || echo '{"Status":"Pending"}')

STATUS=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Status','Pending'))" 2>/dev/null)

case "$STATUS" in
    Success)
        log_success "Producer completed successfully!" ;;
    InProgress)
        log_info "Producer still running in background" ;;
    Failed|Cancelled|TimedOut)
        STDERR=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('StandardErrorContent',''))" 2>/dev/null)
        [ -n "$STDERR" ] && echo "$STDERR"
        log_error "Producer $STATUS" ;;
    *)
        log_info "Producer status: $STATUS" ;;
esac

echo ""
log_success "Demo complete!"
