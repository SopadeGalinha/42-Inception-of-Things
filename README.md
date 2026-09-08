# Inception-of-Things (IoT)

A System Administration project focused on Kubernetes, using K3s and K3d with Vagrant.

## Table of Contents

- [Part 1: K3s and Vagrant](#part-1-k3s-and-vagrant)
- [Part 2: K3s and Three Simple Applications](#part-2-k3s-and-three-simple-applications)
- [Part 3: K3d and Argo CD](#part-3-k3d-and-argo-cd)
- [Bonus: Local GitLab](#bonus-local-gitlab)
- [Running without sudo](#running-without-sudo)

---

## Running without sudo

If the target machine has no `sudo` access for installing Vagrant (e.g. via
apt/HashiCorp's repo), use the portable installer instead — it extracts the
official `.deb` into `$HOME/.local` with no root required, and wires up
`PATH`/`LD_LIBRARY_PATH` in `~/.zshrc`/`~/.bashrc` (idempotently, whichever
shell rc files exist) so a bare `vagrant` command works afterwards, exactly
as the rest of this README (and the subject) describes:

```bash
./scripts/vagrant-install-nosudo.sh
# open a new shell (or `source ~/.zshrc`), then use vagrant normally:
cd p1   # or p2
vagrant up
```

Run the installer once per machine/account — re-running it is a no-op if
Vagrant and the rc block are already in place. If you'd rather not touch
your dotfiles, `scripts/vagrant-wrapper.sh` is a drop-in replacement for a
bare `vagrant` command instead (`../scripts/vagrant-wrapper.sh up`). See the
comments in both scripts for how/why this works, and `TROUBLESHOOTING.md`
for the full story. VirtualBox itself still needs to be genuinely installed
system-wide (it ships setuid-root helpers that need a real install) — only
Vagrant is covered by this workaround.

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
│  │  RAM: 2048 MB       │    │  RAM: 1024 MB       │        │
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
└── scripts/
    ├── setup_server.sh      # K3s server installation script
    └── setup_worker.sh      # K3s agent installation script
```

## Vagrantfile Explained

### Base Box
```ruby
config.vm.box = "ubuntu/jammy64"
```
Uses Ubuntu 22.04 LTS (Jammy Jellyfish) as the base operating system — the newest release Canonical officially publishes under the `ubuntu/` namespace on Vagrant Cloud (24.04 boxes only exist from third-party publishers like `bento/`).

### Server Configuration
```ruby
config.vm.define "jhogoncaS" do |s|
  s.vm.hostname = "jhogoncaS"
  s.vm.network "private_network", ip: "192.168.56.110"
  s.vm.provider "virtualbox" do |vb|
    vb.memory = "2048"
    vb.cpus = 1
  end
  s.vm.provision "shell", path: "scripts/setup_server.sh", env: { "K3S_TOKEN" => k3s_token }
end
```

| Setting | Value | Purpose |
|---------|-------|---------|
| `hostname` | jhogoncaS | Machine name with "S" suffix (Server) as per subject |
| `private_network` | 192.168.56.110 | Dedicated IP for inter-VM communication |
| `memory` | 2048 MB | The subject's advised 512/1024MB was sized for its own screenshots' k3s release (v1.21.4); current stable k3s (v1.36.x) needs more — see `TROUBLESHOOTING.md` |
| `cpus` | 1 | Minimum as specified in subject |

### Worker Configuration
```ruby
config.vm.define "jhogoncaSW" do |sw|
  sw.vm.hostname = "jhogoncaSW"
  sw.vm.network "private_network", ip: "192.168.56.111"
  sw.vm.provider "virtualbox" do |vb|
    vb.memory = "1024"
    vb.cpus = 1
  end
  sw.vm.provision "shell", path: "scripts/setup_worker.sh", env: { "K3S_TOKEN" => k3s_token }
end
```

| Setting | Value | Purpose |
|---------|-------|---------|
| `hostname` | jhogoncaSW | Machine name with "SW" suffix (ServerWorker) as per subject |
| `private_network` | 192.168.56.111 | Dedicated IP for inter-VM communication |
| `memory` | 1024 MB | Bumped from the subject's advised 512MB — see `TROUBLESHOOTING.md` |
| `cpus` | 1 | Minimum as specified in subject |

## Setup Scripts Explained

### setup_server.sh

Installs K3s in **server/controller mode**.

```bash
IFACE=$(ip -4 -o addr show | awk -v ip="$SERVER_IP" '$0 ~ ip {print $2; exit}')

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
    --write-kubeconfig-mode 644 \
    --node-ip ${SERVER_IP} \
    --bind-address ${SERVER_IP} \
    --flannel-iface ${IFACE} \
    --token ${K3S_TOKEN}" sh -
```

| Flag | Purpose |
|------|---------|
| `--write-kubeconfig-mode 644` | Makes the kubeconfig file readable by all users, allowing `kubectl` to work without sudo |
| `--node-ip` | Specifies the IP address to advertise for this node. Uses the private network IP instead of NAT |
| `--bind-address` | IP address the API server listens on. Must match the private network IP |
| `--flannel-iface ${IFACE}` | **See explanation below** |
| `--token ${K3S_TOKEN}` | **See explanation below** |

#### Why detect the interface instead of hardcoding `enp0s8`?

VirtualBox VMs have multiple network interfaces:
- One NAT interface for internet access (10.0.2.x)
- One private-network interface (192.168.56.x)

**Flannel** is the CNI (Container Network Interface) used by K3s for pod networking. By default, Flannel might pick the wrong interface (NAT), causing pods on different nodes to be unable to communicate. The interface name (`enp0s8`, `eth1`, ...) depends on the base box and provider, so instead of hardcoding it, the script looks up whichever interface already has the `192.168.56.x` address assigned and passes that to `--flannel-iface`.

#### Shared cluster token

```bash
k3s_token = "iot-k3s-cluster-token"   # defined once in the Vagrantfile
```

Rather than letting K3s auto-generate a token on the server and copying it to the worker through the `/vagrant` synced folder (which needs a polling loop and depends on VirtualBox shared-folder sync), the Vagrantfile defines a single fixed token and passes it to both provisioning scripts via the `env:` option of `config.vm.provision`. The server starts with `--token ${K3S_TOKEN}`, and the worker joins with the same value — no shared file, no race condition.

### setup_worker.sh

Installs K3s in **agent/worker mode**.

```bash
IFACE=$(ip -4 -o addr show | awk -v ip="$WORKER_IP" '$0 ~ ip {print $2; exit}')

# Wait until the server's API is actually accepting connections
until curl -sk --max-time 2 "https://${SERVER_IP}:6443" >/dev/null 2>&1; do
    sleep 5
done

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent \
    --server https://${SERVER_IP}:6443 \
    --token ${K3S_TOKEN} \
    --node-ip ${WORKER_IP} \
    --flannel-iface ${IFACE}" sh -
```

| Flag | Purpose |
|------|---------|
| `--server` | URL of the K3s server API (port 6443) |
| `--token` | Shared secret configured on the server (see Vagrantfile) |
| `--node-ip` | IP address to advertise for this node |
| `--flannel-iface ${IFACE}` | Auto-detected private-network interface |

The worker waits on an actual TCP/TLS handshake against the server's API port, rather than polling for a token file — it doesn't depend on synced-folder propagation at all.

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
Vagrant automatically syncs the project folder (`p1/`) to `/vagrant/` inside each VM. It isn't needed for the cluster token anymore (that's passed via provisioner environment variables — see [Shared cluster token](#shared-cluster-token) above), but it's still how the provisioning scripts themselves reach the VM.

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
│   │        github.com/SopadeGalinha/42-Inception-of-Things      │    │
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
├── Vagrantfile                   # Single VM (jhogoncaP3) that the whole part runs inside
├── scripts/
│   ├── install_dependencies.sh  # Installs Docker, kubectl and k3d if missing
│   └── setup.sh                 # Main setup script (installs everything)
└── confs/
    ├── argocd-app.yaml          # Argo CD Application resource
    └── app/
        └── deployment.yaml      # wil42/playground app (synced by Argo CD)
```

## Prerequisites

Unlike the subject's own description ("without Vagrant this time"), this
part still runs inside its own single VM (`jhogoncaP3`, plain Ubuntu, no
nested virtualization — it only runs Docker/k3d, not another hypervisor) —
see the note in [Running without sudo](#running-without-sudo). That's what
"Vagrant" is doing here: *inside* that VM there's no more Vagrant, only
Docker/k3d/kubectl, exactly as the subject describes.

`vagrant up` provisions everything automatically by running
`install_dependencies.sh` then `setup.sh` inside the VM — there is nothing
to install manually on the host. `install_dependencies.sh`:

| Tool | How it's installed |
|------|-------------|
| Docker | Official convenience script (`get.docker.com`), enabled as a service |
| kubectl | Official binary release for the detected stable Kubernetes version |
| k3d | Official install script (`k3d-io/k3d/install.sh`) |

Each step is skipped automatically if the tool is already present, so the script is safe to re-run (e.g. via `vagrant provision`).

**The GitHub repo referenced by `p3/confs/argocd-app.yaml` must be public.**
Argo CD's `Application` resource clones it over plain HTTPS with no
credentials configured — this also matches the subject's own requirement
("You must be able to change the version from your **public** GitHub
repository"). If it's private, the Application sits at `SYNC STATUS:
Unknown` forever and nothing deploys to the `dev` namespace.

## Setup Script Explained

The `setup.sh` script performs these steps:

### Step 1: Install Prerequisites
```bash
./install_dependencies.sh   # Installs Docker, kubectl, k3d (skips what's already there)
docker info                 # Then confirms the Docker daemon is reachable
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
cd p3
vagrant up            # provisions the VM and runs setup.sh inside it
vagrant ssh            # then run kubectl/k3d commands from inside jhogoncaP3
```

If `vagrant up` stops at "Docker was installed but the daemon isn't
reachable yet" on a completely fresh VM, that's the documented docker-group
timing gotcha (see `TROUBLESHOOTING.md`) — run `vagrant provision` once more
and it continues past it (Docker/kubectl/k3d are already installed by then,
only the group membership needed a fresh session).

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

---

# Bonus: Local GitLab

This adds a local GitLab instance (Helm chart, official `gitlab/gitlab`
chart) to the Part 3 lab, in its own `gitlab` namespace, acting as an
alternative Git source for the same Argo CD Application.

## File Structure

```
bonus/
├── Vagrantfile                    # Single VM (10GB RAM, 4 CPU — GitLab is heavy)
├── scripts/
│   ├── install_dependencies.sh    # Docker, kubectl, k3d, Helm
│   └── setup.sh                   # Full pipeline, see GIT_SOURCE below
└── confs/
    ├── gitlab-datastores.yaml     # Standalone Postgres/Redis/MinIO for GitLab
    ├── gitlab-values.yaml         # Trimmed Helm values for a local/demo GitLab
    ├── argocd-app-gitlab.yaml     # Argo CD Application sourced from local GitLab
    ├── argocd-app-github.yaml     # Same Application sourced from the public GitHub repo
    └── app/deployment.yaml        # wil42/playground manifests pushed into GitLab
```

## The GIT_SOURCE rule

`setup.sh` reads a `GIT_SOURCE` environment variable to decide which config
Argo CD syncs from — this is the switch between "the bonus" and "the normal
p3 repo config":

```bash
cd bonus
../scripts/vagrant-install-nosudo.sh   # if needed
./setup.sh                              # GIT_SOURCE=gitlab (default): local GitLab
GIT_SOURCE=github ./setup.sh            # same public GitHub repo/path as the mandatory p3
```

| `GIT_SOURCE` | Behavior |
|---|---|
| `gitlab` (default) | Deploys standalone Postgres/Redis/MinIO, installs GitLab via Helm, seeds a `root/playground` project with the app manifests, creates an Argo CD repo credential + `Application` pointing at GitLab's in-cluster service. |
| `github` | Skips the entire GitLab install; applies `bonus/confs/argocd-app-github.yaml` — the exact same public-repo Application already used and tested for the mandatory p3 — proving "everything you did in Part 3" also works unchanged in this environment. |

Both modes were verified in the same running cluster: deleting one
`Application` and applying the other correctly re-synced `dev` from the new
source each time.

## Why GitLab needs its own Postgres/Redis/MinIO

The official `gitlab/gitlab` Helm chart (10.x, appVersion v19.x) no longer
bundles PostgreSQL/Redis/object-storage subcharts — recent chart versions
require external instances for all three, even for a local trial. Rather
than pull in a third-party chart just to satisfy that, `gitlab-datastores.yaml`
runs minimal single-Pod Postgres 17 (chart requires ≥17), Redis, and MinIO
deployments in the same `gitlab` namespace, backed by k3d's default
`local-path` PVCs — no HA, which is fine for a local/demo instance.

## Key fixes needed to get GitLab running locally (see TROUBLESHOOTING.md for full detail)

- **`global.gatewayApi.enabled` defaults to `true`** in this chart version,
  which requires Gateway API CRDs we don't have — disabled in favor of
  plain `nginx-ingress` (the chart's own bundled controller).
- **k3s's built-in Traefik and GitLab's own nginx-ingress both want
  port 80** as a `LoadBalancer` — Traefik is disabled at cluster creation
  (`--k3s-arg "--disable=traefik@server:0"`) so GitLab's controller can bind it.
- **`toolbox`'s default backup config** unconditionally tries to copy an S3
  config file that's never created unless backups are explicitly configured
  — switched `backups.objectStorage.backend` to `azure` (a no-op sleep loop)
  since this bonus never runs backups.
- **Postgres needs `max_locks_per_transaction` raised** (256, from the
  default 64) — GitLab's schema load acquires far more locks than Postgres's
  default allows in one transaction.
- **`webservice`/`sidekiq` memory limits** needed real headroom (2200Mi /
  2000Mi) — the trimmed-down defaults got OOMKilled under actual load.
- **`global.hosts.domain` is a *base* domain**: the chart prepends its own
  `gitlab.` — a domain that already starts with `gitlab.` produces
  `gitlab.gitlab.<domain>`, a hostname nothing routes to.

## Verifying

```bash
cd bonus
../scripts/vagrant-wrapper.sh ssh -c "
  kubectl get applications -n argocd
  kubectl get pods -n dev
"
```

Expected: `wil42-playground` `Synced`/`Healthy`, one pod `Running` in `dev`.
