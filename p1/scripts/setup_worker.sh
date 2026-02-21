#!/bin/bash

# Setup script for K3s Worker (Agent mode)
# This script installs K3s in agent mode and joins the cluster

set -e

# Define IPs
SERVER_IP="192.168.56.110"
WORKER_IP="192.168.56.111"

echo "=== Installing K3s in Agent (Worker) mode ==="

# Wait for the server to be ready and token to be available
echo "=== Waiting for K3s server token ==="
while [ ! -f /vagrant/confs/node-token ]; do
    echo "Waiting for node-token..."
    sleep 5
done

# Get the node token
NODE_TOKEN=$(cat /vagrant/confs/node-token)

# Install K3s in agent mode
# --server: URL of the K3s server to join
# --token: Token for joining the cluster
# --node-ip: IP address to advertise for this node
# --flannel-iface: Network interface for flannel CNI
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent \
    --server https://${SERVER_IP}:6443 \
    --token ${NODE_TOKEN} \
    --node-ip ${WORKER_IP} \
    --flannel-iface enp0s8" sh -

echo "=== K3s Worker setup complete ==="
