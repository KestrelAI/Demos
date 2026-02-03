#!/bin/bash
# Generate load to trigger HPA scaling
# This simulates a traffic spike that would naturally trigger the issue

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(dirname "$SCRIPT_DIR")"

cd "$DEMO_DIR"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

DURATION=${1:-120}  # Default 2 minutes

print_header "Generating Load to Trigger HPA"

echo -e "${YELLOW}This will generate load for $DURATION seconds to trigger HPA scaling.${NC}"
echo ""
echo "In another terminal, run:"
echo "  kubectl get hpa -n payments -w"
echo "  kubectl get pods -n payments -w"
echo ""

# Get load generator pod
LOAD_POD=$(kubectl get pods -n payments -l app=load-generator -o jsonpath='{.items[0].metadata.name}')

if [ -z "$LOAD_POD" ]; then
    echo "Error: Load generator pod not found"
    exit 1
fi

echo -e "${GREEN}Starting load generation from pod: $LOAD_POD${NC}"
echo ""

# Generate load using wget in a loop
# This creates CPU pressure that triggers HPA
kubectl exec -n payments "$LOAD_POD" -- /bin/sh -c "
    echo 'Generating load for $DURATION seconds...'
    END=\$((SECONDS+$DURATION))
    while [ \$SECONDS -lt \$END ]; do
        for i in 1 2 3 4 5 6 7 8 9 10; do
            wget -q -O /dev/null http://payments-api:80/ &
        done
        sleep 0.1
    done
    wait
    echo 'Load generation complete'
"

print_header "Load Generation Complete"
echo "Check the pod status:"
echo "  kubectl get pods -n payments -o wide"
