#!/bin/bash
#===============================================================================
# Bonus: dependency installer
#===============================================================================
# Same as p3/scripts/install_dependencies.sh (Docker, kubectl, k3d) plus
# Helm, needed here to install the GitLab chart. Safe to re-run.
#===============================================================================

set -e

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

log() {
    echo -e "\033[0;34m[INSTALL]\033[0m $1"
}

install_docker() {
    if command -v docker &> /dev/null; then
        log "Docker already installed, skipping."
        return
    fi
    log "Installing Docker..."
    curl -fsSL https://get.docker.com | ${SUDO} sh
    ${SUDO} usermod -aG docker "${SUDO_USER:-$USER}" 2>/dev/null || true
    ${SUDO} systemctl enable --now docker
}

install_kubectl() {
    if command -v kubectl &> /dev/null; then
        log "kubectl already installed, skipping."
        return
    fi
    log "Installing kubectl..."
    local version
    version=$(curl -Ls https://dl.k8s.io/release/stable.txt)
    curl -Lso /tmp/kubectl "https://dl.k8s.io/release/${version}/bin/linux/amd64/kubectl"
    ${SUDO} install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
    rm -f /tmp/kubectl
}

install_k3d() {
    if command -v k3d &> /dev/null; then
        log "k3d already installed, skipping."
        return
    fi
    log "Installing k3d..."
    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | ${SUDO} bash
}

install_helm() {
    if command -v helm &> /dev/null; then
        log "Helm already installed, skipping."
        return
    fi
    log "Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | ${SUDO} bash
}

install_docker
install_kubectl
install_k3d
install_helm

log "All dependencies installed."
