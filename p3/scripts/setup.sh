#!/bin/bash

set -e

CLUSTER_NAME="iot"
ARGOCD_NAMESPACE="argocd"
DEV_NAMESPACE="dev"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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
    local timeout=${2:-300}

    log_info "Waiting for all pods in '$namespace' to be ready (timeout: ${timeout}s)..."

    kubectl wait --for=condition=Ready pods --all \
        -n "$namespace" \
        --timeout="${timeout}s" 2>/dev/null || {
            log_warning "Some pods may not be ready yet, continuing..."
        }
}

verify_prerequisites() {
    log_info "Installing/verifying prerequisites (Docker, kubectl, k3d)..."

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    "$SCRIPT_DIR/install_dependencies.sh"

    if ! id -nG | grep -qw docker && getent group docker | grep -qw "$(id -un)"; then
        log_info "Docker group membership just changed — re-executing with it active..."
        exec sg docker -c "bash $0"
    fi

    if ! docker info &> /dev/null; then
        log_error "Docker was installed but the daemon isn't reachable yet."
        log_info "If Docker was just installed, log out/in (or run 'newgrp docker') and re-run this script."
        exit 1
    fi

    log_success "All prerequisites verified!"
}

setup_kubectl_alias() {
    grep -qxF 'alias k=kubectl' "$HOME/.bashrc" || echo 'alias k=kubectl' >> "$HOME/.bashrc"
    grep -qxF 'source <(kubectl completion bash)' "$HOME/.bashrc" || echo 'source <(kubectl completion bash)' >> "$HOME/.bashrc"
    grep -qxF 'complete -o default -F __start_kubectl k' "$HOME/.bashrc" || echo 'complete -o default -F __start_kubectl k' >> "$HOME/.bashrc"
}

create_cluster() {
    log_info "Creating K3d cluster: $CLUSTER_NAME"

    if k3d cluster list | grep -q "$CLUSTER_NAME"; then
        log_warning "Cluster '$CLUSTER_NAME' already exists. Deleting..."
        k3d cluster delete "$CLUSTER_NAME"
    fi

    k3d cluster create "$CLUSTER_NAME" \
        --api-port 6550 \
        --port "8080:80@loadbalancer" \
        --agents 0 \
        --wait

    kubectl cluster-info

    log_success "K3d cluster '$CLUSTER_NAME' created successfully!"
}

create_namespaces() {
    log_info "Creating namespaces..."

    kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    kubectl create namespace "$DEV_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    log_success "Namespaces created: $ARGOCD_NAMESPACE, $DEV_NAMESPACE"
}

install_argocd() {
    log_info "Installing Argo CD in namespace '$ARGOCD_NAMESPACE'..."

    kubectl apply -n "$ARGOCD_NAMESPACE" --server-side --force-conflicts \
        -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    log_info "Waiting for Argo CD pods to be ready..."
    sleep 10

    wait_for_pods "$ARGOCD_NAMESPACE" 300

    log_success "Argo CD installed successfully!"
}

configure_argocd_access() {
    log_info "Configuring Argo CD access..."

    kubectl patch svc argocd-server -n "$ARGOCD_NAMESPACE" \
        -p '{"spec": {"type": "NodePort"}}'

    kubectl rollout status deployment/argocd-server -n "$ARGOCD_NAMESPACE" --timeout=120s

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

deploy_application() {
    log_info "Deploying application via Argo CD..."

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ARGOCD_APP_MANIFEST="$SCRIPT_DIR/../confs/argocd-app.yaml"

    if [[ ! -f "$ARGOCD_APP_MANIFEST" ]]; then
        log_error "Application manifest not found at: $ARGOCD_APP_MANIFEST"
        exit 1
    fi

    kubectl apply -f "$ARGOCD_APP_MANIFEST"
    log_success "Argo CD Application created!"

    log_info "Waiting for application to sync..."
    sleep 15

    kubectl get applications -n "$ARGOCD_NAMESPACE"
}

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

main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║        Part 3: K3d and Argo CD Setup                         ║"
    echo "║        Inception-of-Things (IoT) Project                     ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    verify_prerequisites
    setup_kubectl_alias
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

main "$@"
