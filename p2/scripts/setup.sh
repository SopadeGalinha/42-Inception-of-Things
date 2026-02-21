#!/bin/bash

# Setup script for K3s Server with 3 web applications
# Part 2: K3s and three simple applications

set -e

# Define the server IP
SERVER_IP="192.168.56.110"

echo "=== Installing K3s in Server mode ==="

# Install K3s in server mode
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
    --write-kubeconfig-mode 644 \
    --node-ip ${SERVER_IP} \
    --bind-address ${SERVER_IP} \
    --flannel-iface enp0s8" sh -

# Wait for K3s to be ready
echo "=== Waiting for K3s to be ready ==="
sleep 15

# Wait for node to be ready
echo "=== Waiting for node to be Ready ==="
kubectl wait --for=condition=Ready node --all --timeout=120s

echo "=== Deploying applications ==="

# Apply all application configurations
kubectl apply -f /vagrant/confs/app1.yaml
kubectl apply -f /vagrant/confs/app2.yaml
kubectl apply -f /vagrant/confs/app3.yaml
kubectl apply -f /vagrant/confs/ingress.yaml

# Wait for deployments to be ready
echo "=== Waiting for deployments to be ready ==="
kubectl wait --for=condition=Available deployment/app1 --timeout=120s
kubectl wait --for=condition=Available deployment/app2 --timeout=120s
kubectl wait --for=condition=Available deployment/app3 --timeout=120s

echo "=== Verifying deployment ==="
kubectl get pods
kubectl get services
kubectl get ingress

echo ""
echo "=== Setup complete! ==="
echo ""
echo "To test the applications, use:"
echo "  curl -H 'Host: app1.com' http://${SERVER_IP}"
echo "  curl -H 'Host: app2.com' http://${SERVER_IP}"
echo "  curl http://${SERVER_IP}  (default -> app3)"
echo ""
