#!/bin/bash

set -e

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

log() {
    echo -e "\033[0;34m[INSTALL]\033[0m $1"
}

install_docker() {
    # A prior run interrupted mid-install (SSH drop, VM halt/reload, host
    # suspend, etc.) can leave the docker-ce packages "unpacked" but never
    # configured: the docker CLI binary is already present (so a plain
    # `command -v docker` check looks satisfied) but the `docker` group and
    # the systemd units were never created, so the daemon can't start.
    # `dpkg --configure -a` is a no-op when nothing is pending, so it's safe
    # to always run before deciding whether a (re)install is needed.
    ${SUDO} dpkg --configure -a 2>/dev/null || true

    if command -v docker &> /dev/null && getent group docker &> /dev/null; then
        log "Docker already installed, skipping install step."
    else
        log "Installing Docker..."
        curl -fsSL https://get.docker.com | ${SUDO} sh
    fi

    # Idempotent regardless of whether install just ran: keep both possible
    # login users (vagrant ssh vs. VirtualBox console as jhogonca) in the
    # docker group and the daemon enabled/running.
    for u in vagrant jhogonca; do
        id "$u" &>/dev/null && ${SUDO} usermod -aG docker "$u"
    done
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

install_docker
install_kubectl
install_k3d

log "All dependencies installed."
