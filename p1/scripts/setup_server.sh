#!/bin/bash

# Setup script for K3s Server (Controller mode)
# This script installs K3s in server mode and configures kubectl

set -e

# Define the server IP
SERVER_IP="192.168.56.110"

echo "=== Installing K3s in Server (Controller) mode ==="

# Install K3s in server mode
# --write-kubeconfig-mode 644: Makes kubeconfig readable by all users
# --node-ip: Sets the IP address to advertise for this node
# --bind-address: IP address to bind the API server to
# --flannel-iface: Network interface for flannel CNI (enp0s8 is typically the private network in VirtualBox)
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
    --write-kubeconfig-mode 644 \
    --node-ip ${SERVER_IP} \
    --bind-address ${SERVER_IP} \
    --flannel-iface enp0s8" sh -

# Wait for K3s to be ready
echo "=== Waiting for K3s to be ready ==="
sleep 10

# Verify K3s is running
echo "=== Verifying K3s installation ==="
kubectl get nodes

# Copy the node token to shared folder for worker to access
echo "=== Copying Node Token for Worker ==="
cp /var/lib/rancher/k3s/server/node-token /vagrant/confs/node-token
cat /vagrant/confs/node-token

echo "=== K3s Server setup complete ==="
