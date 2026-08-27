#!/bin/bash
#===============================================================================
# Bootstrap script for a fresh lab VM (e.g. the base VM you set up at school)
#===============================================================================
# Installs the tools shared by the whole project:
# - git, curl
# - VirtualBox + Vagrant (needed by p1 and p2)
#
# p3's own dependencies (Docker, kubectl, k3d) are installed automatically by
# p3/scripts/install_dependencies.sh, so they're not duplicated here.
#
# Assumes a Debian/Ubuntu base (matches the ubuntu/noble64 Vagrant boxes used
# in p1 and p2). Run with a user that has sudo access.
#===============================================================================

set -e

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

log()  { echo -e "\033[0;34m[BOOTSTRAP]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }

check_nested_virtualization() {
    log "Checking for hardware virtualization support (VT-x/AMD-V)..."
    if grep -Eq '(vmx|svm)' /proc/cpuinfo; then
        log "CPU virtualization extensions are visible to this VM."
    else
        warn "No vmx/svm flag found in /proc/cpuinfo."
        warn "VirtualBox (used by p1 and p2) needs nested virtualization enabled"
        warn "on whatever hypervisor is running THIS VM (e.g. 'Virtualize"
        warn "Intel VT-x/EPT' in VMware, the Nested VT-x/AMD-V option under"
        warn "VirtualBox's own Processor tab, or"
        warn "'Set-VMProcessor -ExposeVirtualizationExtensions \$true' on Hyper-V)."
        warn "p1 and p2 will fail to boot their VMs until this is fixed."
    fi
}

install_base_packages() {
    if command -v git &> /dev/null && command -v curl &> /dev/null; then
        log "git/curl already installed, skipping."
        return
    fi
    log "Installing git/curl..."
    ${SUDO} apt-get update -qq
    ${SUDO} apt-get install -y git curl
}

install_virtualbox() {
    if command -v vboxmanage &> /dev/null; then
        log "VirtualBox already installed, skipping."
        return
    fi
    log "Installing VirtualBox..."
    ${SUDO} apt-get update -qq
    ${SUDO} apt-get install -y virtualbox
}

install_vagrant() {
    if command -v vagrant &> /dev/null; then
        log "Vagrant already installed, skipping."
        return
    fi
    log "Installing Vagrant..."
    ${SUDO} apt-get install -y wget gnupg software-properties-common
    wget -qO- https://apt.releases.hashicorp.com/gpg | ${SUDO} gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
        | ${SUDO} tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
    ${SUDO} apt-get update -qq
    ${SUDO} apt-get install -y vagrant
}

check_nested_virtualization
install_base_packages
install_virtualbox
install_vagrant

log "Base tools ready: git, VirtualBox, Vagrant."
log "Next: cd p1 && vagrant up"
