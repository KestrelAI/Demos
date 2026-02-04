#!/bin/bash
# EKS Anti-Affinity Demo Runner
# This script demonstrates the pod scheduling failure caused by
# required anti-affinity with insufficient nodes.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(dirname "$SCRIPT_DIR")"

cd "$DEMO_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() {
    echo -e "${GREEN}▶ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Get cluster info from Terraform
CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "")
if [ -z "$CLUSTER_NAME" ]; then
    echo "Error: Could not get cluster name. Make sure Terraform has been applied."
    exit 1
fi

REGION=$(terraform output -raw region 2>/dev/null || echo "us-west-2")

# Configure kubectl
print_header "Configuring kubectl"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"

# Show initial state
print_header "Initial State - Everything Works Fine"

print_step "Checking nodes (should have 4):"
kubectl get nodes
echo ""

print_step "Checking pods (should have 2 Running):"
kubectl get pods -n payments -o wide
echo ""

print_step "Checking HPA configuration:"
kubectl get hpa -n payments
echo ""

NODE_COUNT=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
print_warning "Node count: $NODE_COUNT"
print_warning "HPA max replicas: 8"
print_warning "With required anti-affinity, only $NODE_COUNT pods can ever run!"

# Trigger the issue
print_header "Triggering the Scheduling Issue"

print_step "Scaling deployment to 8 replicas (more than available nodes)..."
kubectl scale deployment payments-api -n payments --replicas=8

echo ""
print_step "Waiting 10 seconds for scheduler to attempt placement..."
sleep 10

# Show the problem
print_header "The Problem - Pods Stuck in Pending"

print_step "Pod status (notice Pending pods):"
kubectl get pods -n payments -o wide
echo ""

print_step "Checking why pods are Pending:"
echo ""
kubectl get events -n payments --field-selector reason=FailedScheduling --sort-by='.lastTimestamp' | tail -10
echo ""

# Count pending pods (filter by app label to exclude load-generator)
PENDING=$(kubectl get pods -n payments -l app=payments-api --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
RUNNING=$(kubectl get pods -n payments -l app=payments-api --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')

print_header "Summary"
echo -e "  Nodes available:     ${BLUE}$NODE_COUNT${NC}"
echo -e "  Pods Running:        ${GREEN}$RUNNING${NC}"
echo -e "  Pods Pending:        ${RED}$PENDING${NC}"
echo ""

if [ "$PENDING" -gt 0 ]; then
    print_error "Anti-affinity constraint prevents scheduling!"
    echo ""
    echo "The deployment has 'requiredDuringSchedulingIgnoredDuringExecution'"
    echo "pod anti-affinity, meaning each pod MUST be on a different node."
    echo ""
    echo "With $NODE_COUNT nodes and 8 desired replicas, $PENDING pods cannot be scheduled."
fi

print_header "The Fix"
echo "Option 1: Change to 'preferred' anti-affinity (recommended)"
echo "  kubectl patch deployment payments-api -n payments --type='json' -p='[...]'"
echo ""
echo "Option 2: Add more nodes to match replica count"
echo "  aws eks update-nodegroup-config --scaling-config desiredSize=8"
echo ""
echo "Run: terraform output fix_kubectl_patch"
echo "  to see the full patch command."
