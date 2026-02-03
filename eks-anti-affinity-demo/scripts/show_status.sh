#!/bin/bash
# Show current status of the demo cluster

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
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

print_header "Cluster Nodes"
kubectl get nodes -o wide
echo ""

print_header "Payments Namespace - Pods"
kubectl get pods -n payments -o wide
echo ""

print_header "Payments Namespace - HPA"
kubectl get hpa -n payments
echo ""

print_header "Deployment Details"
kubectl get deployment payments-api -n payments -o jsonpath='{.spec.replicas}' | xargs -I {} echo "Desired replicas: {}"
echo ""

# Check anti-affinity type
AFFINITY_TYPE=$(kubectl get deployment payments-api -n payments -o jsonpath='{.spec.template.spec.affinity.podAntiAffinity}' 2>/dev/null)

if echo "$AFFINITY_TYPE" | grep -q "requiredDuringScheduling"; then
    echo -e "Anti-affinity type: ${RED}required${NC} (can cause scheduling failures)"
elif echo "$AFFINITY_TYPE" | grep -q "preferredDuringScheduling"; then
    echo -e "Anti-affinity type: ${GREEN}preferred${NC} (flexible scheduling)"
else
    echo "Anti-affinity type: none"
fi
echo ""

print_header "Summary"
NODES=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
RUNNING=$(kubectl get pods -n payments -l app=payments-api --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
PENDING=$(kubectl get pods -n payments -l app=payments-api --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')

echo -e "  Nodes:           ${BLUE}$NODES${NC}"
echo -e "  Running pods:    ${GREEN}$RUNNING${NC}"
echo -e "  Pending pods:    ${RED}$PENDING${NC}"

if [ "$PENDING" -gt 0 ]; then
    echo ""
    print_header "Recent Scheduling Failures"
    kubectl get events -n payments --field-selector reason=FailedScheduling --sort-by='.lastTimestamp' | tail -5
fi
