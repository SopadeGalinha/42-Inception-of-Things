#!/bin/bash

# Setup script for K3s Server (Controller mode)
# This script installs K3s in server mode and configures kubectl

set -e

# Define the server IP
SERVER_IP="192.168.56.110"

# Detect the interface that already carries the private-network IP instead
# of hardcoding a name like enp0s8, which can vary across base boxes.
IFACE=$(ip -4 -o addr show | awk -v ip="$SERVER_IP" '$0 ~ ip {print $2; exit}')

echo "=== Installing K3s in Server (Controller) mode ==="
echo "Using network interface: ${IFACE}"

# Install K3s in server mode
# --write-kubeconfig-mode 644: Makes kubeconfig readable by all users
# --node-ip: Sets the IP address to advertise for this node
# --bind-address: IP address to bind the API server to
# --flannel-iface: Network interface for flannel CNI (auto-detected above)
# --token: Fixed shared secret (see Vagrantfile) so the worker can join
#          without depending on the synced folder to relay a generated token
# --disable traefik/metrics-server/servicelb/local-storage: p1 only has to
#          prove the server/agent join and kubectl work (subject's Part 1
#          scope) — none of these addons are exercised here (Ingress is
#          p2's job), so they're just memory overhead on top of the API
#          server/scheduler/controller-manager. coredns is kept enabled.
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
    --write-kubeconfig-mode 644 \
    --node-ip ${SERVER_IP} \
    --bind-address ${SERVER_IP} \
    --flannel-iface ${IFACE} \
    --token ${K3S_TOKEN} \
    --disable traefik \
    --disable metrics-server \
    --disable servicelb \
    --disable local-storage" sh -

# Wait for K3s to be ready
echo "=== Waiting for K3s to be ready ==="
sleep 10

# Verify K3s is running
echo "=== Verifying K3s installation ==="
kubectl get nodes

# Convenience for the live defense: 'k' alias + completion for kubectl.
# Guarded with grep so re-provisioning (vagrant provision) doesn't duplicate
# the lines on every run.
BASHRC="/home/vagrant/.bashrc"
grep -qxF 'alias k=kubectl' "$BASHRC" || echo 'alias k=kubectl' >> "$BASHRC"
grep -qxF 'source <(kubectl completion bash)' "$BASHRC" || echo 'source <(kubectl completion bash)' >> "$BASHRC"
grep -qxF 'complete -o default -F __start_kubectl k' "$BASHRC" || echo 'complete -o default -F __start_kubectl k' >> "$BASHRC"
chown vagrant:vagrant "$BASHRC"

echo "=== K3s Server setup complete ==="
