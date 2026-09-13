#!/bin/bash

set -e

VAGRANT_ROOT="$HOME/.local/vagrant-portable/opt/vagrant"
LIBS_DIR="$HOME/.local/vagrant-portable-libs"

if [ ! -x "$VAGRANT_ROOT/bin/vagrant" ]; then
    echo "Portable Vagrant not found at $VAGRANT_ROOT" >&2
    echo "Run scripts/bootstrap.sh first." >&2
    exit 1
fi

export LD_LIBRARY_PATH="$LIBS_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$VAGRANT_ROOT/bin:$PATH"

exec "$VAGRANT_ROOT/bin/vagrant" "$@"
