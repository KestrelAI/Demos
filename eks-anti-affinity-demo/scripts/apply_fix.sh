#!/bin/bash
# Apply the fix for the anti-affinity scheduling issue
# Changes from 'required' to 'preferred' anti-affinity

set -e

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

print_header "Current State (Before Fix)"

echo "Pods status:"
kubectl get pods -n payments -o wide
echo ""

PENDING_BEFORE=$(kubectl get pods -n payments -l app=payments-api --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo -e "${YELLOW}Pending pods: $PENDING_BEFORE${NC}"

print_header "Applying Fix - Reducing Anti-Affinity Weight"

# Apply the patch to reduce the anti-affinity weight from 100 to 50
kubectl patch deployment payments-api -n payments --type='json' -p='[
  {
    "op": "replace",
    "path": "/spec/template/spec/affinity/podAntiAffinity/preferredDuringSchedulingIgnoredDuringExecution/0/weight",
    "value": 50
  }
]'

echo ""
echo -e "${GREEN}Patch applied successfully!${NC}"
echo ""

print_header "Waiting for Rollout"

kubectl rollout status deployment/payments-api -n payments --timeout=120s

print_header "State After Fix"

echo "Pods status:"
kubectl get pods -n payments -o wide
echo ""

RUNNING_AFTER=$(kubectl get pods -n payments -l app=payments-api --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
PENDING_AFTER=$(kubectl get pods -n payments -l app=payments-api --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')

echo -e "Running pods: ${GREEN}$RUNNING_AFTER${NC}"
echo -e "Pending pods: ${GREEN}$PENDING_AFTER${NC}"

if [ "$PENDING_AFTER" -eq 0 ]; then
    echo ""
    echo -e "${GREEN}SUCCESS! All pods are now running.${NC}"
    echo ""
    echo "With weight reduced from 100 to 50, Kubernetes will:"
    echo "  1. Still prefer spreading pods across nodes"
    echo "  2. But allow co-location when nodes are limited"
    echo ""
    echo "You still get resilience benefits when possible, but scaling isn't blocked."
fi
