#!/bin/bash

set -e

VAGRANT_VERSION="2.4.9"
ARCH="amd64"
DEB_URL="https://releases.hashicorp.com/vagrant/${VAGRANT_VERSION}/vagrant_${VAGRANT_VERSION}-1_${ARCH}.deb"

INSTALL_ROOT="$HOME/.local/vagrant-portable"
LIBS_DIR="$HOME/.local/vagrant-portable-libs"
WORK_DIR="$(mktemp -d)"

log() { echo -e "\033[0;34m[VAGRANT-INSTALL]\033[0m $1"; }

RC_MARKER_START="# --- IoT project tooling (Inception-of-Things, sem sudo neste poste) ---"
RC_MARKER_END="# ------------------------------------------------------------------------"

setup_shell_rc() {
    local block
    block="$RC_MARKER_START
vagrant() {
    LD_LIBRARY_PATH=\"$LIBS_DIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\" \\
    \"$INSTALL_ROOT/opt/vagrant/bin/vagrant\" \"\$@\"
}
$RC_MARKER_END"

    local rc updated=0
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
        [ -f "$rc" ] || continue
        if grep -qF "$RC_MARKER_START" "$rc" 2>/dev/null; then
            log "PATH already wired up in $rc, leaving as-is."
        else
            log "Adding portable Vagrant to PATH in $rc"
            printf '\n%s\n' "$block" >> "$rc"
            updated=1
        fi
    done
    if [ "$updated" -eq 1 ]; then
        log "Open a new shell (or 'source' your rc file) to pick this up."
    fi
}

if [ -x "$INSTALL_ROOT/opt/vagrant/bin/vagrant" ]; then
    log "Already installed at $INSTALL_ROOT — nothing to do."
    setup_shell_rc
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
setup_shell_rc
