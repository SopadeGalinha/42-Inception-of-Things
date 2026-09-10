#!/bin/bash

set -e

SERVER_IP="192.168.56.110"
WORKER_IP="192.168.56.111"

IFACE=$(ip -4 -o addr show | awk -v ip="$WORKER_IP" '$0 ~ ip {print $2; exit}')

echo "=== Installing K3s in Agent (Worker) mode ==="
echo "Using network interface: ${IFACE}"

echo "=== Waiting for K3s server API at ${SERVER_IP}:6443 ==="
until curl -sk --max-time 2 "https://${SERVER_IP}:6443" >/dev/null 2>&1; do
    echo "Server not ready yet, retrying..."
    sleep 5
done

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent \
    --server https://${SERVER_IP}:6443 \
    --token ${K3S_TOKEN} \
    --node-ip ${WORKER_IP} \
    --flannel-iface ${IFACE}" sh -

echo "=== K3s Worker setup complete ==="
