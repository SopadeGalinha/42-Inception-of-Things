#!/bin/bash
#===============================================================================
# No-sudo Vagrant installer
#===============================================================================
# For a machine with NO sudo access (e.g. the school lab account), where the
# normal "sudo apt install vagrant" from scripts/bootstrap.sh isn't an option.
#
# Extracts the official Vagrant .deb into $HOME/.local — no dpkg, no root —
# using only `ar` and `tar`, both plain user-space tools. VirtualBox itself
# still needs to be pre-installed (it ships setuid-root helpers that
# genuinely require a real system install); this script only covers Vagrant.
#
# After running this once, use scripts/vagrant-wrapper.sh instead of a bare
# `vagrant` command, e.g.:
#   ../scripts/vagrant-wrapper.sh up
#===============================================================================

set -e

VAGRANT_VERSION="2.4.9"
ARCH="amd64"
DEB_URL="https://releases.hashicorp.com/vagrant/${VAGRANT_VERSION}/vagrant_${VAGRANT_VERSION}-1_${ARCH}.deb"

INSTALL_ROOT="$HOME/.local/vagrant-portable"
LIBS_DIR="$HOME/.local/vagrant-portable-libs"
WORK_DIR="$(mktemp -d)"

log() { echo -e "\033[0;34m[VAGRANT-INSTALL]\033[0m $1"; }

if [ -x "$INSTALL_ROOT/opt/vagrant/bin/vagrant" ]; then
    log "Already installed at $INSTALL_ROOT — nothing to do."
    exit 0
fi

for tool in ar tar curl; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

log "Downloading Vagrant ${VAGRANT_VERSION} .deb..."
curl -fsSL -o "$WORK_DIR/vagrant.deb" "$DEB_URL"

log "Extracting .deb payload (ar + tar, no dpkg/root needed)..."
(
    cd "$WORK_DIR"
    ar x vagrant.deb
    mkdir -p "$INSTALL_ROOT"
    tar -xf data.tar.* -C "$INSTALL_ROOT"
)

log "Building a narrow LD_LIBRARY_PATH dir (excludes bundled libreadline/libhistory, which break /bin/bash)..."
mkdir -p "$LIBS_DIR"
find "$INSTALL_ROOT/opt/vagrant/embedded/lib" -maxdepth 1 -name '*.so*' | while read -r lib; do
    base="$(basename "$lib")"
    case "$base" in
        libreadline*|libhistory*) continue ;;
    esac
    ln -sf "$lib" "$LIBS_DIR/$base"
done

rm -rf "$WORK_DIR"

log "Installed to $INSTALL_ROOT."
log "Use scripts/vagrant-wrapper.sh instead of a bare 'vagrant' command."
