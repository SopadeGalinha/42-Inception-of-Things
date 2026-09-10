#!/bin/bash

set -e

SERVER_IP="192.168.56.110"

IFACE=$(ip -4 -o addr show | awk -v ip="$SERVER_IP" '$0 ~ ip {print $2; exit}')

echo "=== Installing K3s in Server (Controller) mode ==="
echo "Using network interface: ${IFACE}"

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

echo "=== Waiting for K3s to be ready ==="
sleep 10

echo "=== Verifying K3s installation ==="
kubectl get nodes

BASHRC="/home/vagrant/.bashrc"
grep -qxF 'alias k=kubectl' "$BASHRC" || echo 'alias k=kubectl' >> "$BASHRC"
grep -qxF 'source <(kubectl completion bash)' "$BASHRC" || echo 'source <(kubectl completion bash)' >> "$BASHRC"
grep -qxF 'complete -o default -F __start_kubectl k' "$BASHRC" || echo 'complete -o default -F __start_kubectl k' >> "$BASHRC"
chown vagrant:vagrant "$BASHRC"

echo "=== K3s Server setup complete ==="
