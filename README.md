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
