#!/bin/bash

# Setup script for K3s Worker (Agent mode)
# This script installs K3s in agent mode and joins the cluster

set -e

# Define IPs
SERVER_IP="192.168.56.110"
WORKER_IP="192.168.56.111"

# Detect the interface that already carries the private-network IP instead
# of hardcoding a name like enp0s8, which can vary across base boxes.
IFACE=$(ip -4 -o addr show | awk -v ip="$WORKER_IP" '$0 ~ ip {print $2; exit}')

echo "=== Installing K3s in Agent (Worker) mode ==="
echo "Using network interface: ${IFACE}"

# Wait until the server's API is actually accepting connections, instead of
# polling for a token file to appear on the synced folder.
echo "=== Waiting for K3s server API at ${SERVER_IP}:6443 ==="
until curl -sk --max-time 2 "https://${SERVER_IP}:6443" >/dev/null 2>&1; do
    echo "Server not ready yet, retrying..."
    sleep 5
done

# Install K3s in agent mode
# --server: URL of the K3s server to join
# --token: Shared secret configured on the server (see Vagrantfile)
# --node-ip: IP address to advertise for this node
# --flannel-iface: Network interface for flannel CNI (auto-detected above)
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent \
    --server https://${SERVER_IP}:6443 \
    --token ${K3S_TOKEN} \
    --node-ip ${WORKER_IP} \
    --flannel-iface ${IFACE}" sh -

echo "=== K3s Worker setup complete ==="
