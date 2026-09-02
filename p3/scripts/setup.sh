#!/bin/bash
#===============================================================================
# Part 3: K3d and Argo CD Setup Script
#===============================================================================
# This script sets up a complete GitOps environment with:
# - K3d cluster (Kubernetes in Docker)
# - Argo CD (GitOps continuous delivery)
# - Application deployment via Argo CD
#
# Requirements:
# - Docker installed and running
# - K3d installed
# - kubectl installed
# - Internet connection (to pull images and GitHub repo)
#===============================================================================

set -e  # Exit on any error

#-------------------------------------------------------------------------------
# Configuration Variables
#-------------------------------------------------------------------------------
CLUSTER_NAME="iot"
ARGOCD_NAMESPACE="argocd"
DEV_NAMESPACE="dev"

#-------------------------------------------------------------------------------
# Color codes for pretty output
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#-------------------------------------------------------------------------------
# Helper Functions
#-------------------------------------------------------------------------------
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

wait_for_pods() {
    local namespace=$1
    local timeout=${2:-300}  # Default 5 minutes
    
    log_info "Waiting for all pods in '$namespace' to be ready (timeout: ${timeout}s)..."
    
    kubectl wait --for=condition=Ready pods --all \
        -n "$namespace" \
        --timeout="${timeout}s" 2>/dev/null || {
            log_warning "Some pods may not be ready yet, continuing..."
        }
}

#-------------------------------------------------------------------------------
# Step 1: Install Prerequisites
#-------------------------------------------------------------------------------
verify_prerequisites() {
    log_info "Installing/verifying prerequisites (Docker, kubectl, k3d)..."

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    "$SCRIPT_DIR/install_dependencies.sh"

    if ! docker info &> /dev/null; then
        log_error "Docker was installed but the daemon isn't reachable yet."
        log_info "If Docker was just installed, log out/in (or run 'newgrp docker') and re-run this script."
        exit 1
    fi

    log_success "All prerequisites verified!"
}

#-------------------------------------------------------------------------------
# Step 2: Create K3d Cluster
#-------------------------------------------------------------------------------
create_cluster() {
    log_info "Creating K3d cluster: $CLUSTER_NAME"
    
    # Delete existing cluster if it exists
    if k3d cluster list | grep -q "$CLUSTER_NAME"; then
        log_warning "Cluster '$CLUSTER_NAME' already exists. Deleting..."
        k3d cluster delete "$CLUSTER_NAME"
    fi
    
    # Create new cluster
    # --api-port 6550: Kubernetes API server port
    # --port 8080:80@loadbalancer: Map port 80 from cluster to 8080 on host
    # --agents 0: No additional agent nodes (just server for simplicity)
    # --wait: Wait for cluster to be ready
    k3d cluster create "$CLUSTER_NAME" \
        --api-port 6550 \
        --port "8080:80@loadbalancer" \
        --agents 0 \
        --wait
    
    # Verify cluster is running
    kubectl cluster-info
    
    log_success "K3d cluster '$CLUSTER_NAME' created successfully!"
}

#-------------------------------------------------------------------------------
# Step 3: Create Namespaces
#-------------------------------------------------------------------------------
create_namespaces() {
    log_info "Creating namespaces..."
    
    # Create argocd namespace for Argo CD installation
    kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    # Create dev namespace for our application
    kubectl create namespace "$DEV_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    log_success "Namespaces created: $ARGOCD_NAMESPACE, $DEV_NAMESPACE"
}

#-------------------------------------------------------------------------------
# Step 4: Install Argo CD
#-------------------------------------------------------------------------------
install_argocd() {
    log_info "Installing Argo CD in namespace '$ARGOCD_NAMESPACE'..."
    
    # Install Argo CD using official manifests. --server-side is required:
    # the ApplicationSet CRD is large enough that a client-side apply's
    # kubectl.kubernetes.io/last-applied-configuration annotation exceeds
    # the 256KiB annotation size limit ("metadata.annotations: Too long").
    kubectl apply -n "$ARGOCD_NAMESPACE" --server-side --force-conflicts \
        -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    
    log_info "Waiting for Argo CD pods to be ready..."
    sleep 10  # Give some time for pods to be created
    
    wait_for_pods "$ARGOCD_NAMESPACE" 300
    
    log_success "Argo CD installed successfully!"
}

#-------------------------------------------------------------------------------
# Step 5: Configure Argo CD Access
#-------------------------------------------------------------------------------
configure_argocd_access() {
    log_info "Configuring Argo CD access..."
    
    # Patch the argocd-server service to use NodePort for easy access
    # This allows us to access the Argo CD UI without port-forwarding
    kubectl patch svc argocd-server -n "$ARGOCD_NAMESPACE" \
        -p '{"spec": {"type": "NodePort"}}'
    
    # Wait for the server to be ready
    kubectl rollout status deployment/argocd-server -n "$ARGOCD_NAMESPACE" --timeout=120s
    
    # Get the initial admin password
    # Argo CD generates a random password stored in a secret
    local password
    password=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" | base64 -d)
    
    echo ""
    log_success "Argo CD is ready!"
    echo ""
    echo "======================================"
    echo "      ARGO CD ACCESS CREDENTIALS      "
    echo "======================================"
    echo "Username: admin"
    echo "Password: $password"
    echo "======================================"
    echo ""
    log_info "To access Argo CD UI, run:"
    echo "  kubectl port-forward svc/argocd-server -n $ARGOCD_NAMESPACE 8080:443"
    echo "  Then open: https://localhost:8080"
    echo ""
}

#-------------------------------------------------------------------------------
# Step 6: Deploy Application via Argo CD
#-------------------------------------------------------------------------------
deploy_application() {
    log_info "Deploying application via Argo CD..."

    # Get the directory where this script is located
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ARGOCD_APP_MANIFEST="$SCRIPT_DIR/../confs/argocd-app.yaml"

    if [[ ! -f "$ARGOCD_APP_MANIFEST" ]]; then
        log_error "Application manifest not found at: $ARGOCD_APP_MANIFEST"
        exit 1
    fi

    # Apply the Argo CD Application manifest (source of truth lives in Git,
    # see p3/confs/argocd-app.yaml)
    kubectl apply -f "$ARGOCD_APP_MANIFEST"
    log_success "Argo CD Application created!"

    log_info "Waiting for application to sync..."
    sleep 15  # Give Argo CD time to sync

    # Check application status
    kubectl get applications -n "$ARGOCD_NAMESPACE"
}

#-------------------------------------------------------------------------------
# Step 7: Show Status
#-------------------------------------------------------------------------------
show_status() {
    echo ""
    echo "======================================"
    echo "         DEPLOYMENT STATUS            "
    echo "======================================"
    echo ""
    
    log_info "K3d Clusters:"
    k3d cluster list
    echo ""
    
    log_info "Kubernetes Nodes:"
    kubectl get nodes
    echo ""
    
    log_info "Namespaces:"
    kubectl get namespaces
    echo ""
    
    log_info "Argo CD Pods:"
    kubectl get pods -n "$ARGOCD_NAMESPACE"
    echo ""
    
    log_info "Argo CD Applications:"
    kubectl get applications -n "$ARGOCD_NAMESPACE"
    echo ""
    
    log_info "Dev Namespace Pods:"
    kubectl get pods -n "$DEV_NAMESPACE" 2>/dev/null || echo "No pods yet (Argo CD is syncing...)"
    echo ""
    
    log_info "Dev Namespace Services:"
    kubectl get svc -n "$DEV_NAMESPACE" 2>/dev/null || echo "No services yet"
    echo ""
}

#-------------------------------------------------------------------------------
# Main Execution
#-------------------------------------------------------------------------------
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║        Part 3: K3d and Argo CD Setup                         ║"
    echo "║        Inception-of-Things (IoT) Project                     ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    
    verify_prerequisites
    create_cluster
    create_namespaces
    install_argocd
    configure_argocd_access
    deploy_application
    show_status
    
    echo ""
    log_success "Setup complete!"
    echo ""
    echo "Next steps:"
    echo "1. Access Argo CD UI: kubectl port-forward svc/argocd-server -n argocd 8080:443"
    echo "2. Open https://localhost:8080 in your browser"
    echo "3. Login with credentials shown above"
    echo "4. Watch the application sync and deploy!"
    echo ""
    echo "To update the application:"
    echo "1. Modify p3/confs/app/deployment.yaml (change image tag v1 → v2)"
    echo "2. Git commit and push"
    echo "3. Argo CD will automatically detect and deploy the change"
    echo ""
}

# Run main function
main "$@"
