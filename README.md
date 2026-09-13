# Inception-of-Things (IoT)

K3s + K3d + Vagrant. One Vagrant VM (or k3d cluster) per part.

## Setup (no host sudo required)

```bash
./scripts/bootstrap.sh
# open a new terminal (or: source ~/.bashrc)
```

If `vagrant` still isn't found afterwards, call the binary directly:

```bash
./scripts/vagrant.sh up
```

---

## p1

```bash
cd p1
vagrant up

vagrant ssh jhogoncaS
kubectl get nodes

vagrant destroy -f
```

---

## p2

```bash
cd p2
vagrant up

vagrant ssh jhogoncaS
kubectl get pods
kubectl get ingress

curl -H 'Host: app1.com' http://192.168.56.110
curl -H 'Host: app2.com' http://192.168.56.110
curl http://192.168.56.110

vagrant destroy -f
```

---

## p3

```bash
cd p3
vagrant up      # boots and preps the VM only, nothing installed yet

vagrant ssh     # or VirtualBox console: user jhogonca / password qwerty123

iot-setup       # installs Docker/kubectl/k3d, deploys Argo CD + the app
```

Aliases available inside the VM (from `vagrant up`, even before running `iot-setup`):

| Alias              | Does                                        |
|--------------------|----------------------------------------------|
| `iot-setup`        | Run the full setup                          |
| `argocd-password`  | Print the Argo CD admin password            |
| `k`                | Alias for `kubectl`, with completion        |

From the host, no need to stay inside the VM:

| Service | URL                              |
|---------|-----------------------------------|
| Argo CD | `https://192.168.56.120:8443` (`admin` / `argocd-password`) |
| App     | `http://192.168.56.120:8081`     |

The app is deployed from a teammate's repo (`heitorMP/hmaciel-`), not from
`p3/` in this repo. To demo a version change, push to that repo, then:

```bash
kubectl get applications -n argocd -w
```

```bash
vagrant destroy -f
```

---

## bonus

```bash
cd bonus
vagrant up      # boots and preps the VM only, nothing installed yet

vagrant ssh     # or VirtualBox console: user jhogonca / password qwerty123

bonus-setup                     # local GitLab (default)
GIT_SOURCE=github bonus-setup   # skip GitLab, use GitHub instead
```

Aliases available inside the VM (from `vagrant up`, even before running `bonus-setup`):

| Alias              | Does                                        |
|--------------------|----------------------------------------------|
| `bonus-setup`      | Run the full setup                          |
| `argocd-password`  | Print the Argo CD admin password            |
| `k`                | Alias for `kubectl`, with completion        |

From the host, no need to stay inside the VM:

| Service | URL                              |
|---------|-----------------------------------|
| Argo CD | `https://192.168.56.130:8443` (`admin` / `argocd-password`) |
| App     | `http://192.168.56.130:8081`     |
| GitLab  | `http://gitlab.192.168.56.130.nip.io:8090` (`GIT_SOURCE=gitlab` only) |

```bash
vagrant destroy -f
```
