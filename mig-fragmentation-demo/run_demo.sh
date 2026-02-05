#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

NAMESPACE="mig-demo"
RELEASE_NAME="mig-demo"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          MIG Fragmentation Demo - Kestrel AI               ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check prerequisites
check_prerequisites() {
    echo -e "${YELLOW}Checking prerequisites...${NC}"
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}Error: kubectl is not installed${NC}"
        exit 1
    fi
    
    # Check helm
    if ! command -v helm &> /dev/null; then
        echo -e "${RED}Error: helm is not installed${NC}"
        exit 1
    fi
    
    # Check cluster connection
    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}Error: Cannot connect to Kubernetes cluster${NC}"
        exit 1
    fi
    
    # Check for GPU nodes
    GPU_NODES=$(kubectl get nodes -o json | jq '[.items[] | select(.status.allocatable | keys[] | contains("nvidia.com/"))] | length')
    if [ "$GPU_NODES" -eq "0" ]; then
        echo -e "${YELLOW}Warning: No GPU nodes detected. Demo requires NVIDIA GPUs with MIG enabled.${NC}"
        read -p "Continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        echo -e "${GREEN}✓ Found $GPU_NODES GPU node(s)${NC}"
    fi
    
    # Check for MIG resources
    MIG_RESOURCES=$(kubectl get nodes -o json | jq '[.items[].status.allocatable | keys[] | select(contains("mig-"))] | unique | length')
    if [ "$MIG_RESOURCES" -eq "0" ]; then
        echo -e "${YELLOW}Warning: No MIG resources detected. MIG may not be enabled.${NC}"
    else
        echo -e "${GREEN}✓ MIG resources detected${NC}"
    fi
    
    echo -e "${GREEN}✓ Prerequisites check passed${NC}"
    echo ""
}

# Deploy the demo
deploy_demo() {
    echo -e "${YELLOW}Deploying MIG fragmentation demo...${NC}"
    
    # Check if release exists
    if helm list -n $NAMESPACE | grep -q $RELEASE_NAME; then
        echo -e "${YELLOW}Existing release found. Upgrading...${NC}"
        helm upgrade $RELEASE_NAME ./chart -n $NAMESPACE
    else
        echo -e "${YELLOW}Installing new release...${NC}"
        helm install $RELEASE_NAME ./chart -n $NAMESPACE --create-namespace
    fi
    
    echo -e "${GREEN}✓ Demo deployed${NC}"
    echo ""
}

# Watch pods
watch_pods() {
    echo -e "${YELLOW}Watching pod status...${NC}"
    echo -e "${BLUE}Press Ctrl+C to stop watching${NC}"
    echo ""
    
    kubectl get pods -n $NAMESPACE -w
}

# Show fragmentation status
show_status() {
    echo -e "${YELLOW}Current pod status:${NC}"
    kubectl get pods -n $NAMESPACE
    echo ""
    
    echo -e "${YELLOW}Training job status:${NC}"
    kubectl describe pod -n $NAMESPACE -l app=mig-training 2>/dev/null | grep -A 10 "Events:" || echo "Training job not found"
    echo ""
    
    echo -e "${YELLOW}Node MIG resources:${NC}"
    kubectl get nodes -o=custom-columns='NAME:.metadata.name,MIG-1G-5GB:.status.allocatable.nvidia\.com/mig-1g\.5gb,MIG-2G-10GB:.status.allocatable.nvidia\.com/mig-2g\.10gb,MIG-3G-20GB:.status.allocatable.nvidia\.com/mig-3g\.20gb'
    echo ""
}

# Cleanup
cleanup() {
    echo -e "${YELLOW}Cleaning up demo...${NC}"
    helm uninstall $RELEASE_NAME -n $NAMESPACE 2>/dev/null || true
    kubectl delete namespace $NAMESPACE 2>/dev/null || true
    echo -e "${GREEN}✓ Cleanup complete${NC}"
}

# Help
show_help() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  deploy    Deploy the MIG fragmentation demo"
    echo "  watch     Watch pod status"
    echo "  status    Show current fragmentation status"
    echo "  cleanup   Remove all demo resources"
    echo "  help      Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 deploy    # Deploy the demo"
    echo "  $0 watch     # Watch pods until training job gets stuck"
    echo "  $0 status    # Check why training job is pending"
    echo "  $0 cleanup   # Clean up when done"
}

# Main
case "${1:-deploy}" in
    deploy)
        check_prerequisites
        deploy_demo
        echo -e "${GREEN}Demo deployed! Run '$0 watch' to observe the fragmentation.${NC}"
        ;;
    watch)
        watch_pods
        ;;
    status)
        show_status
        ;;
    cleanup)
        cleanup
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        show_help
        exit 1
        ;;
esac
