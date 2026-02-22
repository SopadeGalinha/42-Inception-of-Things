# Inception-of-Things (IoT)

A System Administration project focused on Kubernetes, using K3s and K3d with Vagrant.

## Table of Contents

- [Part 1: K3s and Vagrant](#part-1-k3s-and-vagrant)
- [Part 2: K3s and Three Simple Applications](#part-2-k3s-and-three-simple-applications)
- [Part 3: K3d and Argo CD](#part-3-k3d-and-argo-cd) *(coming soon)*

---

# Part 1: K3s and Vagrant

This part sets up a K3s cluster with two virtual machines using Vagrant: one **Server** (controller) and one **Worker** (agent).

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│                     Host Machine                           │
│                                                            │
│  ┌─────────────────────┐    ┌─────────────────────┐        │
│  │    jhogoncaS        │    │    jhogoncaSW       │        │
│  │    (Server)         │    │    (Worker)         │        │
│  │                     │    │                     │        │
│  │  IP: 192.168.56.110 │    │  IP: 192.168.56.111 │        │
│  │  K3s: controller    │◄───│  K3s: agent         │        │
│  │  RAM: 1024 MB       │    │  RAM: 512 MB        │        │
│  │  CPU: 1             │    │  CPU: 1             │        │
│  └─────────────────────┘    └─────────────────────┘        │
│              │                        │                    │
│              └────────┬───────────────┘                    │
│                       │                                    │
│              private_network (192.168.56.0/24)             │
└────────────────────────────────────────────────────────────┘
```

## File Structure

```
p1/
├── Vagrantfile              # VM definitions and configuration
├── confs/
│   └── node-token           # Auto-generated K3s join token
└── scripts/
    ├── setup_server.sh      # K3s server installation script
    └── setup_worker.sh      # K3s agent installation script
```

## Vagrantfile Explained

### Base Box
```ruby
config.vm.box = "ubuntu/bionic64"
```
Uses Ubuntu 18.04 LTS as the base operating system. This is a stable, well-supported distribution for K3s.

### Server Configuration
```ruby
config.vm.define "jhogoncaS" do |s|
  s.vm.hostname = "jhogoncaS"
  s.vm.network "private_network", ip: "192.168.56.110"
  s.vm.provider "virtualbox" do |vb|
    vb.memory = "1024"
    vb.cpus = 1
  end
  s.vm.provision "shell", path: "scripts/setup_server.sh"
end
```

| Setting | Value | Purpose |
|---------|-------|---------|
| `hostname` | jhogoncaS | Machine name with "S" suffix (Server) as per subject |
| `private_network` | 192.168.56.110 | Dedicated IP for inter-VM communication |
| `memory` | 1024 MB | Minimum recommended for K3s server |
| `cpus` | 1 | Minimum as specified in subject |

### Worker Configuration
```ruby
config.vm.define "jhogoncaSW" do |sw|
  sw.vm.hostname = "jhogoncaSW"
  sw.vm.network "private_network", ip: "192.168.56.111"
  sw.vm.provider "virtualbox" do |vb|
    vb.memory = "512"
    vb.cpus = 1
  end
  sw.vm.provision "shell", path: "scripts/setup_worker.sh"
end
```

| Setting | Value | Purpose |
|---------|-------|---------|
| `hostname` | jhogoncaSW | Machine name with "SW" suffix (ServerWorker) as per subject |
| `private_network` | 192.168.56.111 | Dedicated IP for inter-VM communication |
| `memory` | 512 MB | Minimum as specified in subject |
| `cpus` | 1 | Minimum as specified in subject |

## Setup Scripts Explained

### setup_server.sh

Installs K3s in **server/controller mode**.

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
    --write-kubeconfig-mode 644 \
    --node-ip ${SERVER_IP} \
    --bind-address ${SERVER_IP} \
    --flannel-iface enp0s8" sh -
```

| Flag | Purpose |
|------|---------|
| `--write-kubeconfig-mode 644` | Makes the kubeconfig file readable by all users, allowing `kubectl` to work without sudo |
| `--node-ip` | Specifies the IP address to advertise for this node. Uses the private network IP instead of NAT |
| `--bind-address` | IP address the API server listens on. Must match the private network IP |
| `--flannel-iface enp0s8` | **See explanation below** |

#### Why `--flannel-iface enp0s8`?

VirtualBox VMs have multiple network interfaces:
- `enp0s3` (or `eth0`): NAT interface for internet access (10.0.2.x)
- `enp0s8` (or `eth1`): Private network interface (192.168.56.x)

**Flannel** is the CNI (Container Network Interface) used by K3s for pod networking. By default, Flannel might pick the wrong interface (NAT), causing pods on different nodes to be unable to communicate.

Setting `--flannel-iface enp0s8` forces Flannel to use the private network interface, ensuring proper pod-to-pod communication across nodes.

#### Token Sharing

```bash
cp /var/lib/rancher/k3s/server/node-token /vagrant/confs/node-token
```

The server generates a unique token that workers need to join the cluster. This token is copied to `/vagrant/confs/` which is a **synced folder** - it maps to `p1/confs/` on the host machine, making it accessible to both VMs.

### setup_worker.sh

Installs K3s in **agent/worker mode**.

```bash
# Wait for token
while [ ! -f /vagrant/confs/node-token ]; do
    sleep 5
done

NODE_TOKEN=$(cat /vagrant/confs/node-token)

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent \
    --server https://${SERVER_IP}:6443 \
    --token ${NODE_TOKEN} \
    --node-ip ${WORKER_IP} \
    --flannel-iface enp0s8" sh -
```

| Flag | Purpose |
|------|---------|
| `--server` | URL of the K3s server API (port 6443) |
| `--token` | Authentication token to join the cluster |
| `--node-ip` | IP address to advertise for this node |
| `--flannel-iface enp0s8` | Use private network for pod networking |

## Usage

### Start the cluster
```bash
cd p1
vagrant up
```

### SSH into machines
```bash
vagrant ssh jhogoncaS    # Server
vagrant ssh jhogoncaSW   # Worker
```

### Test connectivity between nodes
From the server, ping the worker:
```bash
vagrant ssh jhogoncaS
ping 192.168.56.111 -c 3
```

From the worker, ping the server:
```bash
vagrant ssh jhogoncaSW
ping 192.168.56.110 -c 3
```

### Verify cluster status (from server)
```bash
vagrant ssh jhogoncaS
kubectl get nodes
```

Expected output:
```
NAME         STATUS   ROLES                  AGE   VERSION
jhogoncas    Ready    control-plane,master   Xm    vX.X.X+k3s1
jhogoncasw   Ready    <none>                 Xm    vX.X.X+k3s1
```

### Stop the cluster
```bash
vagrant halt
```

### Destroy the cluster
```bash
vagrant destroy -f
```

## Key Concepts

### K3s
K3s is a lightweight Kubernetes distribution designed for resource-constrained environments. It packages all Kubernetes components into a single binary under 100MB.

### Controller vs Agent
- **Controller (Server)**: Runs the Kubernetes control plane components (API server, scheduler, controller manager) and can also run workloads
- **Agent (Worker)**: Runs workloads only, connects to the controller for instructions

### Private Network
The `private_network` in Vagrant creates a host-only network that allows:
- VMs to communicate with each other
- Host to communicate with VMs
- VMs are isolated from external networks (except through NAT)

### Synced Folders
Vagrant automatically syncs the project folder (`p1/`) to `/vagrant/` inside each VM. This is used to share the node-token between server and worker.

---

# Part 2: K3s and Three Simple Applications

This part demonstrates **Ingress routing** in Kubernetes by deploying three web applications on a single K3s server, accessible via different hostnames.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  Client Request                                                     │
│  curl -H 'Host: app2.com' http://192.168.56.110                     │
│                                                                     │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │
                                  ▼ port 80
┌─────────────────────────────────────────────────────────────────────┐
│  VM jhogoncaS (192.168.56.110)                                      │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  TRAEFIK (Ingress Controller)                                 │  │
│  │                                                               │  │
│  │  Routing Rules:                                               │  │
│  │  ┌─────────────────────────────────────────────────────────┐  │  │
│  │  │  Host: app1.com  →  app1-service:5678  (1 replica)      │  │  │
│  │  │  Host: app2.com  →  app2-service:5678  (3 replicas)     │  │  │
│  │  │  Default         →  app3-service:5678  (1 replica)      │  │  │
│  │  └─────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────┘  │
│         │                    │                    │                 │
│         ▼                    ▼                    ▼                 │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐            │
│  │   Service   │     │   Service   │     │   Service   │            │
│  │ app1-service│     │ app2-service│     │ app3-service│            │
│  └──────┬──────┘     └──────┬──────┘     └──────┬──────┘            │
│         │                   │                   │                   │
│         ▼                   ▼                   ▼                   │
│    ┌────────┐    ┌────────┬────────┬────────┐  ┌────────┐           │
│    │  Pod   │    │  Pod   │  Pod   │  Pod   │  │  Pod   │           │
│    │  app1  │    │  app2  │  app2  │  app2  │  │  app3  │           │
│    └────────┘    └────────┴────────┴────────┘  └────────┘           │
│                        (3 replicas)                                 │
└─────────────────────────────────────────────────────────────────────┘
```

## File Structure

```
p2/
├── Vagrantfile              # Single VM configuration
├── confs/
│   ├── app1.yaml            # Deployment + Service for app1
│   ├── app2.yaml            # Deployment + Service for app2 (3 replicas)
│   ├── app3.yaml            # Deployment + Service for app3 (default)
│   └── ingress.yaml         # Ingress routing rules
└── scripts/
    └── setup.sh             # K3s installation + app deployment
```

## How It Works

### The Request Flow

When you make a request to the VM, here's what happens:

```
1. HTTP Request arrives at VM (192.168.56.110:80)
   Header: "Host: app2.com"
              │
              ▼
2. Traefik (Ingress Controller) receives the request
   - Reads the "Host" header
   - Looks up matching Ingress rules
              │
              ▼
3. Ingress Rule matched: app2.com → app2-service:5678
              │
              ▼
4. Service (app2-service) receives the request
   - Looks up pods with label "app=app2"
   - Load balances across 3 pods
              │
              ▼
5. Pod responds: "Hello from app2!"
```

### Kubernetes Components Explained

#### 1. Deployment (app2.yaml)

A Deployment ensures a specified number of pod replicas are running at all times.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app2
spec:
  replicas: 3                    # ◄── Maintain 3 pods
  selector:
    matchLabels:
      app: app2                  # ◄── Manage pods with this label
  template:
    metadata:
      labels:
        app: app2                # ◄── Label applied to created pods
    spec:
      containers:
      - name: app2
        image: hashicorp/http-echo
        args: ["-text=Hello from app2!", "-listen=:5678"]
```

**Self-healing**: If a pod crashes, the Deployment automatically creates a new one to maintain 3 replicas.

#### 2. Service (app2.yaml)

A Service provides a stable IP address and DNS name for accessing pods. Pods are ephemeral and their IPs change - Services solve this problem.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: app2-service
spec:
  selector:
    app: app2                    # ◄── Route traffic to pods with this label
  ports:
  - port: 5678
    targetPort: 5678
```

**How it finds pods**: The Service watches for pods with the label `app=app2` and automatically updates its endpoint list when pods are created or destroyed.

#### 3. Ingress (ingress.yaml)

Ingress exposes HTTP routes from outside the cluster to Services inside the cluster.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
spec:
  rules:
  - host: app1.com               # ◄── If Host header = app1.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app1-service   # ◄── Route to this service
            port:
              number: 5678
  - host: app2.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app2-service
            port:
              number: 5678
  - http:                        # ◄── No host = default route
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app3-service
            port:
              number: 5678
```

### Labels & Selectors: The Glue

Kubernetes components discover each other through **labels** (key-value pairs) and **selectors** (queries).

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│  Deployment                        Pods                          │
│  ┌─────────────────────┐          ┌──────────────────┐           │
│  │ selector:           │          │ labels:          │           │
│  │   app: app2    ─────┼─────────►│   app: app2      │ MATCH     │
│  └─────────────────────┘          └──────────────────┘           │
│                                   ┌──────────────────┐           │
│                       ───────────►│   app: app1      │ NO MATCH  │
│                                   └──────────────────┘           │
│                                                                  │
│   Service                                                        │
│  ┌─────────────────────┐                                         │
│  │ selector:           │                                         │
│  │   app: app2    ─────┼────────────────────────────► Same pods! │
│  └─────────────────────┘                                         │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Ingress vs DNS

| | DNS | Ingress |
|--|-----|---------|
| **What it does** | Resolves domain → IP | Routes by Host header → Service |
| **Where** | Internet/Network | Inside Kubernetes cluster |
| **Example** | `app1.com → 93.184.216.34` | `Host: app1.com → app1-service` |

Since we don't have real DNS, we simulate the `Host` header with `curl -H 'Host: app1.com'`.

## Usage

### Start the VM
```bash
cd p2
vagrant up
```

### SSH and verify
```bash
vagrant ssh jhogoncaS

# Check all components
kubectl get nodes
kubectl get deployments
kubectl get pods
kubectl get services
kubectl get ingress
```

### Test the routing
```bash
# Inside the VM:

# Test app1 (Host: app1.com)
curl -H 'Host: app1.com' http://192.168.56.110
# → Hello from app1!

# Test app2 (Host: app2.com)
curl -H 'Host: app2.com' http://192.168.56.110
# → Hello from app2!

# Test default (no specific host)
curl http://192.168.56.110
# → Hello from app3 (default)!

# Test unknown host (falls back to default)
curl -H 'Host: unknown.com' http://192.168.56.110
# → Hello from app3 (default)!
```

### Verify app2 has 3 replicas
```bash
kubectl get pods -l app=app2
```

Expected output:
```
NAME                    READY   STATUS    RESTARTS   AGE
app2-xxxxxxxxx-xxxxx   1/1     Running   0          5m
app2-xxxxxxxxx-yyyyy   1/1     Running   0          5m
app2-xxxxxxxxx-zzzzz   1/1     Running   0          5m
```

### Test self-healing
```bash
# Delete a pod and watch it recreate
kubectl delete pod -l app=app2 --wait=false
kubectl get pods -l app=app2 -w
```

### Useful debugging commands
```bash
# View pod logs
kubectl logs -l app=app1

# Describe a service (shows endpoints)
kubectl describe service app2-service

# View Ingress details
kubectl describe ingress app-ingress

# Check Traefik logs
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik
```

### Stop/Destroy
```bash
vagrant halt      # Stop VM
vagrant destroy -f  # Delete VM
```

## Key Concepts

### Ingress Controller (Traefik)
K3s comes with **Traefik** pre-installed as the Ingress Controller. It watches for Ingress resources and automatically configures routing rules. When you create an Ingress YAML, Traefik picks it up and starts routing traffic accordingly.

### Why ClusterIP Services?
Our Services use the default type `ClusterIP`, which means they're only accessible inside the cluster. The **Ingress** is what exposes them externally on port 80. This pattern allows multiple services to share a single entry point.

### Pod Replicas and Load Balancing
With `replicas: 3` for app2, the Service automatically load-balances requests across all 3 pods using round-robin. If you make multiple requests to `app2.com`, they'll be distributed across different pods.

---

# Part 3: K3d and Argo CD

This part sets up a complete GitOps pipeline using **K3d** (Kubernetes in Docker) and **Argo CD** (GitOps continuous delivery tool). Instead of VMs, we run Kubernetes directly in Docker containers.

## What is K3d?

**K3d** is a lightweight wrapper to run **K3s** (lightweight Kubernetes) in Docker. It creates Kubernetes clusters as Docker containers, which is:
- **Fast**: Seconds to create a cluster (vs minutes for VMs)
- **Lightweight**: No VM overhead, just containers
- **Portable**: Works anywhere Docker runs (Linux, macOS, Windows WSL2)

```
┌─────────────────────────────────────────────────────────────────┐
│                      Host Machine (WSL2)                        │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                    Docker                                │    │
│  │                                                          │    │
│  │   ┌─────────────────┐    ┌─────────────────┐            │    │
│  │   │   K3d Server    │    │   K3d LB        │            │    │
│  │   │   (K3s in       │    │   (Traefik)     │            │    │
│  │   │    Docker)      │◄───│   Port: 8080    │◄───────────│────│── External
│  │   │                 │    │                 │            │    │   Access
│  │   └─────────────────┘    └─────────────────┘            │    │
│  │                                                          │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## What is Argo CD?

**Argo CD** is a GitOps continuous delivery tool for Kubernetes. It follows the **GitOps** principle:

> **Git is the single source of truth**

Instead of manually running `kubectl apply`, Argo CD:
1. Watches a Git repository for changes
2. Compares the desired state (Git) with the actual state (cluster)
3. Automatically synchronizes differences

```
┌──────────────────────────────────────────────────────────────────────┐
│                           GitOps Flow                                │
│                                                                      │
│   ┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐   │
│   │  GitHub  │────>│  Argo CD │────>│   K8s    │────>│   App    │   │
│   │   Repo   │     │  (watch) │     │ Cluster  │     │ Running  │   │
│   └──────────┘     └──────────┘     └──────────┘     └──────────┘   │
│        │                ^                                 │          │
│        │                │                                 │          │
│        │         Compare & Sync                           │          │
│        │                │                                 │          │
│        └────────────────┴─────────────────────────────────┘          │
│                                                                      │
│   Developer pushes ──> Argo CD detects ──> Auto deploys to cluster   │
└──────────────────────────────────────────────────────────────────────┘
```

## Architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│                           Part 3 Architecture                              │
│                                                                            │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                        K3d Cluster                                  │  │
│   │                                                                     │  │
│   │   ┌─────────────────────────────────────┐                           │  │
│   │   │          argocd namespace           │                           │  │
│   │   │                                     │                           │  │
│   │   │   ┌─────────────────────────────┐   │                           │  │
│   │   │   │        Argo CD              │   │                           │  │
│   │   │   │  - argocd-server (UI/API)   │   │                           │  │
│   │   │   │  - argocd-repo-server       │   │    Watches & Syncs        │  │
│   │   │   │  - argocd-application-ctrl  │───│──────────────────────┐    │  │
│   │   │   │  - argocd-redis             │   │                      │    │  │
│   │   │   │  - argocd-dex-server        │   │                      │    │  │
│   │   │   └─────────────────────────────┘   │                      │    │  │
│   │   │                                     │                      │    │  │
│   │   └─────────────────────────────────────┘                      │    │  │
│   │                                                                 │    │  │
│   │   ┌─────────────────────────────────────┐                      │    │  │
│   │   │            dev namespace            │                      │    │  │
│   │   │                                     │                      │    │  │
│   │   │   ┌─────────────────────────────┐   │                      │    │  │
│   │   │   │    wil42/playground:v1      │<──│──────────────────────┘    │  │
│   │   │   │    (or v2 after update)     │   │    Deploys from Git       │  │
│   │   │   └─────────────────────────────┘   │                           │  │
│   │   │                                     │                           │  │
│   │   └─────────────────────────────────────┘                           │  │
│   │                                                                     │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                            │
│                                    │                                       │
│                                    │ Syncs from                            │
│                                    ▼                                       │
│   ┌──────────────────────────────────────────────────────────────────┐    │
│   │                         GitHub Repository                         │    │
│   │              github.com/SopadeGalinha/42-Inception-of-Things      │    │
│   │                                                                   │    │
│   │    p3/confs/app/deployment.yaml  ←─── Source of truth for app    │    │
│   │                                                                   │    │
│   └──────────────────────────────────────────────────────────────────┘    │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

## File Structure

```
p3/
├── scripts/
│   └── setup.sh              # Main setup script (installs everything)
└── confs/
    ├── argocd-app.yaml       # Argo CD Application resource
    └── app/
        └── deployment.yaml   # wil42/playground app (synced by Argo CD)
```

## Prerequisites

Before running Part 3, ensure you have:

| Tool | Installation |
|------|-------------|
| Docker | Must be running |
| K3d | `curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \| bash` |
| kubectl | Usually bundled with K3d, or install separately |

## Setup Script Explained

The `setup.sh` script performs these steps:

### Step 1: Verify Prerequisites
```bash
docker info          # Check Docker is running
k3d version          # Check K3d is installed
```

### Step 2: Create K3d Cluster
```bash
k3d cluster create iot \
    --api-port 6550 \              # Kubernetes API on port 6550
    --port "8080:80@loadbalancer" \ # Expose port 80 as 8080 on host
    --agents 0 \                   # No agent nodes (just server)
    --wait                         # Wait for cluster ready
```

### Step 3: Create Namespaces
```bash
kubectl create namespace argocd   # For Argo CD installation
kubectl create namespace dev      # For our application
```

### Step 4: Install Argo CD
```bash
kubectl apply -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

This installs the following Argo CD components:

| Component | Purpose |
|-----------|---------|
| `argocd-server` | API server and Web UI |
| `argocd-repo-server` | Clones and caches Git repos |
| `argocd-application-controller` | Monitors apps and syncs state |
| `argocd-redis` | Caching layer |
| `argocd-dex-server` | Authentication (SSO) |

### Step 5: Configure Access
```bash
# Change service type from ClusterIP to NodePort for easy access
kubectl patch svc argocd-server -n argocd \
    -p '{"spec": {"type": "NodePort"}}'

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d
```

### Step 6: Deploy Application via Argo CD
The script applies the `argocd-app.yaml` which tells Argo CD to:
- Watch: `github.com/SopadeGalinha/42-Inception-of-Things`
- Path: `p3/confs/app/`
- Deploy to: `dev` namespace

## Argo CD Application Resource

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: wil42-playground
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/SopadeGalinha/42-Inception-of-Things.git
    targetRevision: HEAD
    path: p3/confs/app
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      prune: true      # Delete removed resources
      selfHeal: true   # Revert manual changes
```

### Sync Policy Explained

| Setting | Effect |
|---------|--------|
| `automated` | Automatically apply changes (no manual sync needed) |
| `prune: true` | If you remove a resource from Git, it's deleted from cluster |
| `selfHeal: true` | If someone manually changes the cluster, Argo CD reverts it |

## The Application: wil42/playground

The `wil42/playground` image is a simple web server with two versions:

| Version | Response |
|---------|----------|
| `v1` | Shows version 1 message |
| `v2` | Shows version 2 message |

### deployment.yaml
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wil42-playground
  namespace: dev
spec:
  replicas: 1
  selector:
    matchLabels:
      app: wil42-playground
  template:
    metadata:
      labels:
        app: wil42-playground
    spec:
      containers:
        - name: playground
          image: wil42/playground:v1   # ← Change to v2 to trigger update
          ports:
            - containerPort: 8888
---
apiVersion: v1
kind: Service
metadata:
  name: wil42-playground-service
  namespace: dev
spec:
  selector:
    app: wil42-playground
  ports:
    - port: 8888
      targetPort: 8888
```

## Usage

### Quick Start
```bash
cd p3/scripts
./setup.sh
```

### Manual Argo CD Access
```bash
# Port-forward to access Argo CD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Open in browser
# https://localhost:8080
# Username: admin
# Password: (shown by setup script)
```

### Check Application Status
```bash
# View Argo CD applications
kubectl get applications -n argocd

# View deployed pods
kubectl get pods -n dev

# View services
kubectl get svc -n dev

# Check app logs
kubectl logs -n dev -l app=wil42-playground
```

### Test the Application
```bash
# Port-forward to access the app
kubectl port-forward svc/wil42-playground-service -n dev 8888:8888

# In another terminal:
curl http://localhost:8888
```

## Demonstrating CI/CD (v1 → v2)

This is the key demonstration for Part 3. Follow these steps:

### 1. Verify Current Version
```bash
# Check the current image
kubectl get deployment wil42-playground -n dev \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
# Output: wil42/playground:v1
```

### 2. Update the Git Repository
Edit `p3/confs/app/deployment.yaml`:
```yaml
# Change this line:
image: wil42/playground:v1
# To:
image: wil42/playground:v2
```

### 3. Commit and Push
```bash
git add p3/confs/app/deployment.yaml
git commit -m "feat(p3): update playground to v2"
git push
```

### 4. Watch Argo CD Sync
```bash
# Watch the application sync status
kubectl get applications -n argocd -w

# Or watch pods rolling update
kubectl get pods -n dev -w
```

### 5. Verify New Version
```bash
kubectl get deployment wil42-playground -n dev \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
# Output: wil42/playground:v2
```

## Argo CD UI Walkthrough

After running `kubectl port-forward svc/argocd-server -n argocd 8080:443`:

1. **Open** https://localhost:8080
2. **Login** with admin / (password from setup)
3. **View Application**: Click on `wil42-playground`
4. **See Resources**: Deployment, Service, ReplicaSet, Pod
5. **Watch Sync**: After Git push, see "OutOfSync" → "Synced"

## Cleanup

```bash
# Delete the K3d cluster (removes everything)
k3d cluster delete iot

# Verify
k3d cluster list
docker ps  # Should show no K3d containers
```

## Key Concepts

### GitOps Benefits

| Benefit | Description |
|---------|-------------|
| **Auditability** | Git history tracks all changes |
| **Rollback** | `git revert` to restore previous state |
| **Consistency** | Cluster always matches Git |
| **Automation** | No manual `kubectl apply` needed |
| **Security** | Cluster credentials stay in cluster |

### Argo CD vs Traditional CI/CD

| Aspect | Traditional CI/CD | GitOps (Argo CD) |
|--------|------------------|------------------|
| Deployment trigger | CI pipeline pushes to cluster | Cluster pulls from Git |
| Credential storage | CI system has cluster creds | Cluster pulls using pull-based model |
| State management | Applied changes may drift | Continuous sync prevents drift |
| Rollback | Re-run old pipeline | `git revert` |

### Why Two Namespaces?

| Namespace | Purpose |
|-----------|---------|
| `argocd` | Houses Argo CD itself (operator) |
| `dev` | Houses the managed application |

This separation follows best practices:
- Argo CD is infrastructure
- Applications are workloads
- Different RBAC rules can apply
