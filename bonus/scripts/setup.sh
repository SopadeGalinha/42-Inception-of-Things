#!/bin/bash

set -e

GIT_SOURCE="${GIT_SOURCE:-gitlab}"

CLUSTER_NAME="iot-bonus"
ARGOCD_NAMESPACE="argocd"
DEV_NAMESPACE="dev"
GITLAB_NAMESPACE="gitlab"
GITLAB_RELEASE="gitlab"
GITLAB_ROOT_PAT="bonus-seed-token"
GITLAB_PROJECT_PATH="root/playground"

# Service deployed into $DEV_NAMESPACE by the Argo CD Application, whichever
# GIT_SOURCE is used (the "gitlab" source seeds the repo from this same
# bonus/confs/app directory, so the Service name/port match either way).
APP_SERVICE="color-app-service"
APP_SERVICE_PORT="8080"

# Host-reachable ports for the persistent port-forwards (see
# setup_portforwards below). The VM has a dedicated IP on the host-only
# network (192.168.56.130), so these are reachable straight from the host.
ARGOCD_FORWARD_PORT="8443"
APP_FORWARD_PORT="8081"

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

verify_prerequisites() {
    log_info "Installing/verifying prerequisites (Docker, kubectl, k3d, Helm)..."

    bash /vagrant/scripts/install_dependencies.sh

    if ! id -nG | grep -qw docker && getent group docker | grep -qw "$(id -un)"; then
        log_info "Docker group membership just changed — re-executing with it active..."
        exec sg docker -c "bash /vagrant/scripts/setup.sh"
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

# Whichever user actually ran this script (vagrant via SSH, or jhogonca via
# the VirtualBox console) ends up with the working kubeconfig in $HOME; copy
# it to the other login too, and always to /home/vagrant since the
# port-forward systemd services (User=vagrant) rely on finding it there.
sync_kubeconfig_for_other_users() {
    local src="$HOME/.kube/config"

    for u in vagrant jhogonca; do
        [ "$u" = "$(id -un)" ] && continue
        id "$u" &>/dev/null || continue

        local home
        home=$(getent passwd "$u" | cut -d: -f6)
        sudo install -d -m 700 -o "$u" -g "$u" "$home/.kube"
        sudo cp "$src" "$home/.kube/config"
        sudo chown "$u:$u" "$home/.kube/config"
    done
}

create_cluster() {
    log_info "Creating K3d cluster: $CLUSTER_NAME"

    if k3d cluster list | grep -q "$CLUSTER_NAME"; then
        log_warning "Cluster '$CLUSTER_NAME' already exists. Deleting..."
        k3d cluster delete "$CLUSTER_NAME"
    fi

    k3d cluster create "$CLUSTER_NAME" \
        --api-port 6551 \
        --port "8090:80@loadbalancer" \
        --port "8453:443@loadbalancer" \
        --agents 0 \
        --k3s-arg "--disable=traefik@server:0" \
        --wait \
        --timeout 120s

    kubectl cluster-info

    sync_kubeconfig_for_other_users

    log_success "K3d cluster '$CLUSTER_NAME' created successfully!"
}

create_namespaces() {
    log_info "Creating namespaces..."
    kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace "$DEV_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    log_success "Namespaces created: $ARGOCD_NAMESPACE, $DEV_NAMESPACE"
}

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

    local host_ip="192.168.56.130"
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
        git commit -q -m "seed: color-app manifests"
        git push -f "http://root:${GITLAB_ROOT_PAT}@gitlab.${GITLAB_DOMAIN}:8090/${GITLAB_PROJECT_PATH}.git" main:main
    )
    rm -rf "$seed_dir"

    log_success "GitLab repo seeded: ${GITLAB_PROJECT_PATH}"
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

# Persistent kubectl port-forward, exposed on every interface (so it's
# reachable from the host over the private network) and kept alive by
# systemd: Restart=always + StartLimitIntervalSec=0 means it reconnects on
# its own (a few seconds' hiccup, never a manual re-run) whenever Argo CD
# syncs/recreates the target pod, and it survives `vagrant halt`/`vagrant up`
# since the unit is enabled.
setup_portforward_service() {
    local unit_name=$1 svc=$2 ns=$3 port_map=$4 description=$5
    local unit_path="/etc/systemd/system/${unit_name}.service"

    log_info "Configuring persistent port-forward: $description"

    sudo tee "$unit_path" > /dev/null <<EOF
[Unit]
Description=$description
After=network.target docker.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=vagrant
Environment=KUBECONFIG=/home/vagrant/.kube/config
ExecStart=/usr/local/bin/kubectl port-forward --address 0.0.0.0 svc/${svc} -n ${ns} ${port_map}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now "${unit_name}.service"
}

setup_portforwards() {
    setup_portforward_service \
        "argocd-portforward" "argocd-server" "$ARGOCD_NAMESPACE" \
        "${ARGOCD_FORWARD_PORT}:443" "Argo CD UI port-forward"

    setup_portforward_service \
        "app-portforward" "$APP_SERVICE" "$DEV_NAMESPACE" \
        "${APP_FORWARD_PORT}:${APP_SERVICE_PORT}" "Dev app port-forward"

    log_success "Port-forwards are running as systemd services (persist across syncs and reboots)."
}

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
        log_info "GIT_SOURCE=github: applying bonus/confs/argocd-app-github.yaml (points at this repo's own bonus/confs/app)."
        kubectl apply -f "/vagrant/confs/argocd-app-github.yaml"
    fi

    log_success "Argo CD Application created!"
    wait_for_sync "color-app"
    kubectl get applications -n "$ARGOCD_NAMESPACE"
}

# A transient repo-server hiccup (e.g. redis/repo-server still starting up)
# can leave the Application controller stuck reporting sync status
# "Unknown" instead of retrying on its own. Poll instead of a blind sleep,
# and nudge it once with a hard refresh if it's still stuck partway through
# the timeout.
wait_for_sync() {
    local app_name=$1
    local timeout=${2:-180}
    local elapsed=0
    local refreshed=false
    local sync_status=""

    log_info "Waiting for '$app_name' to sync (timeout: ${timeout}s)..."

    while (( elapsed < timeout )); do
        sync_status=$(kubectl get application "$app_name" -n "$ARGOCD_NAMESPACE" \
            -o jsonpath='{.status.sync.status}' 2>/dev/null)

        if [[ "$sync_status" == "Synced" ]]; then
            log_success "'$app_name' synced!"
            return
        fi

        if [[ "$sync_status" == "Unknown" && "$refreshed" == false && $elapsed -ge 30 ]]; then
            log_warning "Sync status stuck at 'Unknown' — forcing a hard refresh..."
            kubectl annotate application "$app_name" -n "$ARGOCD_NAMESPACE" \
                argocd.argoproj.io/refresh=hard --overwrite &>/dev/null
            refreshed=true
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    log_warning "'$app_name' did not report Synced within ${timeout}s (current: ${sync_status:-unknown})."
    log_warning "Check manually: kubectl get application $app_name -n $ARGOCD_NAMESPACE"
}

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
    setup_portforwards
    show_status

    echo ""
    log_success "Setup complete!"
    echo ""
    echo "Everything is already running and reachable from the HOST (no need"
    echo "to stay inside the VM):"
    echo "  Argo CD UI : https://192.168.56.130:${ARGOCD_FORWARD_PORT}  (admin / password shown above, or run: argocd-password)"
    echo "  Dev app    : http://192.168.56.130:${APP_FORWARD_PORT}"
    if [ "$GIT_SOURCE" = "gitlab" ]; then
        echo "  GitLab     : http://gitlab.${GITLAB_DOMAIN}:8090 (root / see GitLab pod logs or the UI's first-login flow for the password)"
    fi
    echo ""
    echo "argocd-portforward and app-portforward are systemd services: they"
    echo "auto-restart on sync/pod changes and survive 'vagrant halt' +"
    echo "'vagrant up'. Check with: systemctl status argocd-portforward app-portforward"
    echo ""
}

main "$@"
