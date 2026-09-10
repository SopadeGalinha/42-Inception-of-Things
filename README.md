# Inception-of-Things (IoT)

K3s + K3d + Vagrant. Comandos para testar cada parte.

## Sem sudo (só a primeira vez)

```bash
./scripts/vagrant-install-nosudo.sh
# abrir novo terminal (ou source ~/.zshrc)
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
vagrant up
```

**Abrir o Argo CD:**

```bash
vagrant ssh -c "kubectl port-forward --address 0.0.0.0 svc/argocd-server -n argocd 8443:443"
vagrant ssh -c "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath={.data.password} | base64 -d"
```

→ `https://192.168.56.120:8443` — user `admin`, password do comando acima.

**Abrir a app:**

```bash
kubectl get svc -n dev   # confirma o nome do service (depende do repo atual do Argo CD)
vagrant ssh -c "kubectl port-forward --address 0.0.0.0 svc/<nome> -n dev 8081:8080"
```

→ `http://192.168.56.120:8081`

**Demo CI/CD (mudar versão):**

```bash
# edita p3/confs/app/deployment.yaml (tag da imagem)
git add p3/confs/app/deployment.yaml
git commit -m "feat(p3): update app version"
git push

kubectl get applications -n argocd -w
```

```bash
vagrant destroy -f
```

---

## bonus

```bash
cd bonus
vagrant up          # GIT_SOURCE=gitlab por default
```

Testar com GitHub em vez do GitLab local:

```bash
vagrant ssh -c "GIT_SOURCE=github bash /vagrant/scripts/setup.sh"
```

**Argo CD e app:** mesmos passos do p3, mas VM em `192.168.56.130`.

```bash
vagrant destroy -f
```
