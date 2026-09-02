#!/bin/bash
#===============================================================================
# No-sudo Vagrant wrapper
#===============================================================================
# Runs the official Vagrant .deb payload without ever needing root: no
# `dpkg`, no `apt`, no `sudo`. This exists because the school lab account has
# no sudo permission at all, so the normal "sudo apt install vagrant" /
# "sudo dpkg -i vagrant.deb" path is not available.
#
# How it works:
#   1. install.sh (this directory) extracts the official vagrant_*.deb with
#      `ar x` + `tar xzf` into ~/.local/vagrant-portable — no root needed,
#      `ar`/`tar` are plain user-space tools.
#   2. Vagrant's own launcher is a statically-linked Go binary
#      (opt/vagrant/bin/vagrant) that execs into a bundled Ruby runtime under
#      opt/vagrant/embedded/. That embedded Ruby needs its bundled shared
#      libraries (libssl, libcurl, libarchive, ...) found via
#      LD_LIBRARY_PATH, since they're not installed system-wide.
#   3. We do NOT point LD_LIBRARY_PATH at the whole embedded/lib directory:
#      Vagrant's bundled libreadline/libhistory are ABI-incompatible with the
#      system's own (breaks /bin/bash and any subprocess Vagrant shells out
#      to with "undefined symbol: UP"). Instead ~/.local/vagrant-portable-libs
#      holds symlinks to every bundled .so EXCEPT libreadline*/libhistory*,
#      so only Vagrant/Ruby's own dynamic loads are affected.
#   4. VirtualBox's setuid-root helpers (VBoxNetAdpCtl, for hostonly network
#      creation) still work fine here because this is a plain
#      LD_LIBRARY_PATH env var on a normal process — NOT a user namespace /
#      mount namespace sandbox (like bwrap). The kernel only strips
#      setuid/setgid privilege for processes that have entered an
#      unprivileged user namespace; a plain env var does not do that.
#===============================================================================

set -e

VAGRANT_ROOT="$HOME/.local/vagrant-portable/opt/vagrant"
LIBS_DIR="$HOME/.local/vagrant-portable-libs"

if [ ! -x "$VAGRANT_ROOT/bin/vagrant" ]; then
    echo "Portable Vagrant not found at $VAGRANT_ROOT" >&2
    echo "Run scripts/vagrant-install-nosudo.sh first." >&2
    exit 1
fi

export LD_LIBRARY_PATH="$LIBS_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$VAGRANT_ROOT/bin:$PATH"

exec "$VAGRANT_ROOT/bin/vagrant" "$@"
