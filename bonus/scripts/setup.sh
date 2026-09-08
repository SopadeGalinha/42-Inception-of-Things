#!/bin/bash
#===============================================================================
# Bonus: local GitLab added to the Part 3 lab (K3d + Argo CD)
#===============================================================================
# Same K3d + Argo CD lab as p3, plus a local GitLab instance (Helm chart, in
# its own "gitlab" namespace) acting as an alternative Git source for the
# Argo CD Application.
#
# GIT_SOURCE selects which config Argo CD syncs from — this is "the rule to
# use the bonus or the normal repo config" the setup was built around:
#   GIT_SOURCE=gitlab (default) -> local GitLab (this bonus), repo seeded
#                                   automatically by this script
#   GIT_SOURCE=github           -> the exact same public GitHub repo/path
#                                   already used (and tested) for p3, via
#                                   bonus/confs/argocd-app-github.yaml (a
#                                   deliberate copy of p3/confs/argocd-app.yaml
#                                   — bonus runs in its own VM with only this
#                                   folder synced, so it can't reach across
#                                   into ../p3/) — proves "everything from
#                                   Part 3" still works unchanged here too
#
#   GIT_SOURCE=github ./setup.sh
#===============================================================================

set -e

GIT_SOURCE="${GIT_SOURCE:-gitlab}"

CLUSTER_NAME="iot-bonus"
ARGOCD_NAMESPACE="argocd"
DEV_NAMESPACE="dev"
GITLAB_NAMESPACE="gitlab"
GITLAB_RELEASE="gitlab"
GITLAB_ROOT_PAT="bonus-seed-token"
GITLAB_PROJECT_PATH="root/playground"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

wait_for_pods() {
    local namespace=$1
    local timeout=${2:-300}
    log_info "Waiting for all pods in '$namespace' to be ready (timeout: ${timeout}s)..."
    kubectl wait --for=condition=Ready pods --all -n "$namespace" --timeout="${timeout}s" 2>/dev/null || {
        log_warning "Some pods may not be ready yet, continuing..."
    }
}

#-------------------------------------------------------------------------------
# Step 1: Install Prerequisites
#-------------------------------------------------------------------------------
verify_prerequisites() {
    log_info "Installing/verifying prerequisites (Docker, kubectl, k3d, Helm)..."

    # Not $(dirname "${BASH_SOURCE[0]}"): Vagrant's shell provisioner copies
    # this script to a /tmp/vagrant-shell* path before running it, so a
    # self-relative lookup can't find its sibling scripts/confs. /vagrant is
    # this VM's synced copy of the bonus/ folder, always at a fixed path.
    # Invoked with `bash` rather than executed directly: VirtualBox's vboxsf
    # shared-folder mount doesn't reliably preserve the execute bit set on
    # the host side.
    bash /vagrant/scripts/install_dependencies.sh

    if ! docker info &> /dev/null; then
        log_error "Docker was installed but the daemon isn't reachable yet."
        log_info "If Docker was just installed, log out/in (or run 'newgrp docker') and re-run this script."
        exit 1
    fi

    log_success "All prerequisites verified!"
}

#-------------------------------------------------------------------------------
# Step 1b: kubectl convenience alias
#-------------------------------------------------------------------------------
setup_kubectl_alias() {
    # Convenience for the live defense: 'k' alias + completion for kubectl.
    # Guarded with grep so re-provisioning (vagrant provision) doesn't
    # duplicate the lines on every run. Unlike p1/p2, this VM's provisioner
    # already runs as vagrant (privileged: false, see Vagrantfile), so
    # $HOME/.bashrc is already the right file/owner without a chown.
    grep -qxF 'alias k=kubectl' "$HOME/.bashrc" || echo 'alias k=kubectl' >> "$HOME/.bashrc"
    grep -qxF 'source <(kubectl completion bash)' "$HOME/.bashrc" || echo 'source <(kubectl completion bash)' >> "$HOME/.bashrc"
    grep -qxF 'complete -o default -F __start_kubectl k' "$HOME/.bashrc" || echo 'complete -o default -F __start_kubectl k' >> "$HOME/.bashrc"
}

#-------------------------------------------------------------------------------
# Step 2: Create K3d Cluster
#-------------------------------------------------------------------------------
create_cluster() {
    log_info "Creating K3d cluster: $CLUSTER_NAME"

    if k3d cluster list | grep -q "$CLUSTER_NAME"; then
        log_warning "Cluster '$CLUSTER_NAME' already exists. Deleting..."
        k3d cluster delete "$CLUSTER_NAME"
    fi

    # Separate API/loadbalancer ports from p3's own cluster so both can run
    # side by side on the same host if needed. Traefik (k3s's built-in
    # ingress) is disabled: GitLab's own chart deploys its own nginx-ingress
    # controller as a LoadBalancer service, and the two fight over port 80 —
    # whichever's svclb DaemonSet grabs the node port first wins, leaving
    # the other's pods stuck Pending and traffic silently 404ing on the
    # loser's default backend.
    k3d cluster create "$CLUSTER_NAME" \
        --api-port 6551 \
        --port "8090:80@loadbalancer" \
        --port "8453:443@loadbalancer" \
        --agents 0 \
        --k3s-arg "--disable=traefik@server:0" \
        --wait \
        --timeout 120s

    kubectl cluster-info
    log_success "K3d cluster '$CLUSTER_NAME' created successfully!"
}

#-------------------------------------------------------------------------------
# Step 3: Create Namespaces
#-------------------------------------------------------------------------------
create_namespaces() {
    log_info "Creating namespaces..."
    kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace "$DEV_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    log_success "Namespaces created: $ARGOCD_NAMESPACE, $DEV_NAMESPACE"
}

#-------------------------------------------------------------------------------
# Step 4: Install local GitLab (only for GIT_SOURCE=gitlab)
#-------------------------------------------------------------------------------
install_gitlab() {
    log_info "Deploying standalone Postgres/Redis/MinIO for GitLab (namespace: $GITLAB_NAMESPACE)..."
    kubectl apply -f "/vagrant/confs/gitlab-datastores.yaml"
    kubectl wait --for=condition=Ready pod -l app=postgres -n "$GITLAB_NAMESPACE" --timeout=90s
    kubectl wait --for=condition=Ready pod -l app=redis -n "$GITLAB_NAMESPACE" --timeout=90s
    kubectl wait --for=condition=Ready pod -l app=minio -n "$GITLAB_NAMESPACE" --timeout=90s
    kubectl wait --for=condition=complete job/minio-create-buckets -n "$GITLAB_NAMESPACE" --timeout=90s

    log_info "Adding the GitLab Helm repo and installing the chart (this pulls several GB of images and can take 10-15 minutes)..."
    helm repo add gitlab https://charts.gitlab.io/ 2>/dev/null || true
    helm repo update gitlab

    # Matches the static private_network IP declared in this folder's own
    # Vagrantfile. Deliberately not auto-detected from `ip addr`: this VM
    # has both a NAT interface (10.0.2.x) and this private-network one, and
    # picking "whichever interface comes first" is unreliable across boxes.
    local host_ip="192.168.56.130"
    # global.hosts.domain is a BASE domain — the chart prepends its own
    # "gitlab." (and "kas.", "registry.", ...) to form each service's actual
    # hostname, so this must NOT already start with "gitlab.". GITLAB_DOMAIN
    # is script-global: seed_gitlab_repo() and deploy_application() both
    # need it too.
    GITLAB_DOMAIN="${host_ip}.nip.io"
    log_info "Using nip.io base domain: ${GITLAB_DOMAIN} -> GitLab will be at gitlab.${GITLAB_DOMAIN} (resolves to this VM's own IP, no real DNS needed)"

    sed "s/DOMAIN_PLACEHOLDER/${GITLAB_DOMAIN}/" "/vagrant/confs/gitlab-values.yaml" > /tmp/gitlab-values-final.yaml

    if helm status "$GITLAB_RELEASE" -n "$GITLAB_NAMESPACE" &>/dev/null; then
        helm upgrade "$GITLAB_RELEASE" gitlab/gitlab -n "$GITLAB_NAMESPACE" -f /tmp/gitlab-values-final.yaml --timeout 900s
    else
        helm install "$GITLAB_RELEASE" gitlab/gitlab -n "$GITLAB_NAMESPACE" -f /tmp/gitlab-values-final.yaml --timeout 900s
    fi

    log_info "Waiting for GitLab's webservice/toolbox/gitaly pods to be ready (this is the slow part)..."
    kubectl wait --for=condition=Ready pod -l app=webservice -n "$GITLAB_NAMESPACE" --timeout=900s
    kubectl wait --for=condition=Ready pod -l app=toolbox -n "$GITLAB_NAMESPACE" --timeout=300s

    log_success "GitLab is up at http://gitlab.${GITLAB_DOMAIN}:8090 (root / see password below)"
}

#-------------------------------------------------------------------------------
# Step 5: Seed the local GitLab repo with the p3-style app manifests
#-------------------------------------------------------------------------------
seed_gitlab_repo() {
    log_info "Creating a root Personal Access Token inside GitLab..."
    kubectl exec -n "$GITLAB_NAMESPACE" deploy/gitlab-toolbox -- gitlab-rails runner "
        token = User.find_by_username('root').personal_access_tokens.find_or_initialize_by(name: 'bonus-seed')
        token.scopes = [:api, :write_repository]
        token.expires_at = 365.days.from_now
        token.set_token('${GITLAB_ROOT_PAT}')
        token.save!
    "

    log_info "Creating the '${GITLAB_PROJECT_PATH}' project via the GitLab API..."
    curl -sf --header "PRIVATE-TOKEN: ${GITLAB_ROOT_PAT}" \
        --header "Host: gitlab.${GITLAB_DOMAIN}" \
        "http://127.0.0.1:8090/api/v4/projects?name=playground&visibility=public" \
        -X POST -d '' > /dev/null || log_warning "Project may already exist, continuing."

    log_info "Pushing the app manifests into GitLab..."
    local seed_dir
    seed_dir=$(mktemp -d)
    cp -r "/vagrant/confs/app/." "$seed_dir/"

    (
        cd "$seed_dir"
        git init -q -b main
        git config user.email "bonus@example.com"
        git config user.name "bonus-seed"
        git add .
        git commit -q -m "seed: wil42-playground manifests"
        # Push through the ingress hostname (not a bare IP/port): git-over-http
        # derives the vhost purely from the URL, and ingress-nginx routes by
        # Host header — nip.io resolves this hostname straight back to this
        # VM's own IP, so no /etc/hosts entry is needed.
        git push -f "http://root:${GITLAB_ROOT_PAT}@gitlab.${GITLAB_DOMAIN}:8090/${GITLAB_PROJECT_PATH}.git" main:main
    )
    rm -rf "$seed_dir"

    log_success "GitLab repo seeded: ${GITLAB_PROJECT_PATH}"
}

#-------------------------------------------------------------------------------
# Step 6: Install Argo CD
#-------------------------------------------------------------------------------
install_argocd() {
    log_info "Installing Argo CD in namespace '$ARGOCD_NAMESPACE'..."
    kubectl apply -n "$ARGOCD_NAMESPACE" --server-side --force-conflicts \
        -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    log_info "Waiting for Argo CD pods to be ready..."
    sleep 10
    wait_for_pods "$ARGOCD_NAMESPACE" 300
    log_success "Argo CD installed successfully!"
}

#-------------------------------------------------------------------------------
# Step 7: Configure Argo CD Access
#-------------------------------------------------------------------------------
configure_argocd_access() {
    log_info "Configuring Argo CD access..."
    kubectl patch svc argocd-server -n "$ARGOCD_NAMESPACE" -p '{"spec": {"type": "NodePort"}}'
    kubectl rollout status deployment/argocd-server -n "$ARGOCD_NAMESPACE" --timeout=120s

    local password
    password=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" | base64 -d)

    echo ""
    log_success "Argo CD is ready!"
    echo "Username: admin"
    echo "Password: $password"
    echo ""
}

#-------------------------------------------------------------------------------
# Step 8: Wire the Argo CD Application to the selected source
#-------------------------------------------------------------------------------
deploy_application() {

    if [ "$GIT_SOURCE" = "gitlab" ]; then
        log_info "GIT_SOURCE=gitlab: creating an Argo CD repo credential + Application pointed at the local GitLab."

        kubectl -n "$ARGOCD_NAMESPACE" create secret generic gitlab-local-repo \
            --from-literal=type=git \
            --from-literal=url="http://gitlab-webservice-default.${GITLAB_NAMESPACE}.svc.cluster.local:8181/${GITLAB_PROJECT_PATH}.git" \
            --from-literal=username=root \
            --from-literal=password="${GITLAB_ROOT_PAT}" \
            --dry-run=client -o yaml | kubectl label -f - --local -o yaml \
                argocd.argoproj.io/secret-type=repository | kubectl apply -f -

        sed "s#GITLAB_REPO_URL_PLACEHOLDER#http://gitlab-webservice-default.${GITLAB_NAMESPACE}.svc.cluster.local:8181/${GITLAB_PROJECT_PATH}.git#" \
            "/vagrant/confs/argocd-app-gitlab.yaml" | kubectl apply -f -
    else
        log_info "GIT_SOURCE=github: applying bonus/confs/argocd-app-github.yaml (same public repo/path already used for the mandatory p3)."
        kubectl apply -f "/vagrant/confs/argocd-app-github.yaml"
    fi

    log_success "Argo CD Application created!"
    log_info "Waiting for application to sync..."
    sleep 15
    kubectl get applications -n "$ARGOCD_NAMESPACE"
}

#-------------------------------------------------------------------------------
# Step 9: Show Status
#-------------------------------------------------------------------------------
show_status() {
    echo ""
    echo "======================================"
    echo "         DEPLOYMENT STATUS            "
    echo "======================================"
    echo ""
    log_info "GIT_SOURCE: $GIT_SOURCE"
    echo ""
    log_info "K3d Clusters:"; k3d cluster list; echo ""
    log_info "Kubernetes Nodes:"; kubectl get nodes; echo ""
    log_info "Namespaces:"; kubectl get namespaces; echo ""
    if [ "$GIT_SOURCE" = "gitlab" ]; then
        log_info "GitLab Pods:"; kubectl get pods -n "$GITLAB_NAMESPACE"; echo ""
    fi
    log_info "Argo CD Applications:"; kubectl get applications -n "$ARGOCD_NAMESPACE"; echo ""
    log_info "Dev Namespace Pods:"; kubectl get pods -n "$DEV_NAMESPACE" 2>/dev/null || echo "No pods yet"; echo ""
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║        Bonus: local GitLab + Part 3 lab (GIT_SOURCE=$GIT_SOURCE)"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    verify_prerequisites
    setup_kubectl_alias
    create_cluster
    create_namespaces

    if [ "$GIT_SOURCE" = "gitlab" ]; then
        install_gitlab
        seed_gitlab_repo
    fi

    install_argocd
    configure_argocd_access
    deploy_application
    show_status

    echo ""
    log_success "Setup complete!"
}

main "$@"
