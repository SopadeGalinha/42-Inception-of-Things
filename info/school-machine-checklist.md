# School machine checklist — before running the project there

Personal reference for the actual defense session. Not part of the graded
repo. Assumes the school bare-metal machine described in
`TROUBLESHOOTING.md`: no `sudo` for the student account, Claude Code (if used
there) runs inside a Flatpak sandbox, VirtualBox and Docker are already
preinstalled on the host.

**Architecture decided for this environment**: single-level virtualization,
straight on the bare host. No `iot-base` wrapper VM (see
`info/iot-base-vm-config.md` for why that was abandoned). p1 and p2 each
create their own Vagrant VM(s) directly on the host; p3 runs in one more VM
of the same kind. This satisfies "the whole project has to be done in a
virtual machine" per-part, without double-nesting.

## 1. Confirm the environment matches assumptions

```bash
# No sudo? (expected: Sorry, user <you> may not run sudo)
sudo -n true

# VirtualBox already installed?
VBoxManage --version

# You're in the vboxusers group (needed for /dev/vboxdrv, /dev/vboxnetctl)?
groups | grep -o vboxusers

# Nested-virt not needed here, but confirm you're not accidentally inside
# another VM/container already:
systemd-detect-virt
```

If `VBoxManage --version` fails or you're not in `vboxusers`, stop and ask —
those need real admin action and can't be worked around from a user account.

## 2. Install Vagrant without sudo

```bash
git clone <your-repo-url>
cd <repo>
./scripts/vagrant-install-nosudo.sh
```

This downloads the official `vagrant_2.4.9-1_amd64.deb` and extracts it into
`~/.local/vagrant-portable` with `ar`/`tar` (no `dpkg`, no root). See the
comments in `scripts/vagrant-install-nosudo.sh` and
`scripts/vagrant-wrapper.sh` for exactly why this works (short version: the
Vagrant Go launcher just execs a bundled Ruby that needs `LD_LIBRARY_PATH`
pointed at its bundled `.so` files — no privilege of any kind is involved).

Sanity check:

```bash
./scripts/vagrant-wrapper.sh --version
# Vagrant 2.4.9
```

## 3. Confirm VirtualBox's setuid helpers still work for your user

Vagrant's `private_network` needs `VBoxManage hostonlyif create`, which
shells out to the setuid-root `VBoxNetAdpCtl` binary. This works fine for a
normal shell (it did at home) — it only breaks if you're running from inside
an unprivileged user namespace (some sandboxing tools, e.g. `bwrap`, put you
in one; a plain terminal does not). If you must drive this from Claude Code's
sandboxed shell, use `flatpak-spawn --host` to escape the Flatpak sandbox for
this and any other VirtualBox/network command.

```bash
VBoxManage hostonlyif create   # should succeed instantly
VBoxManage hostonlyif remove vboxnet<N>   # clean up the test one
```

If this fails with "Permission denied" opening `/dev/vboxnetctl`, you're
inside some kind of namespace sandbox — get a plain terminal (or
`flatpak-spawn --host bash`) and retry there.

## 4. Run p1

```bash
cd p1
../scripts/vagrant-wrapper.sh up
```

Expect it to take a few minutes (base box import + 2 VMs + k3s install on
each). Verify:

```bash
../scripts/vagrant-wrapper.sh ssh jhogoncaS -c "kubectl get nodes"
# both jhogoncaS and jhogoncaSW should show Ready
```

If the worker hangs on "Waiting to retrieve agent configuration" with
`context deadline exceeded`, it's memory pressure, not networking — see
`TROUBLESHOOTING.md`. Current `p1/Vagrantfile` is already sized for this
(2048MB server / 1024MB worker); don't shrink it back down to the subject's
literal 512/1024MB advice.

## 5. Run p2

```bash
cd ../p2
../scripts/vagrant-wrapper.sh up
```

Verify the three apps route correctly:

```bash
../scripts/vagrant-wrapper.sh ssh jhogoncaS -c "
  curl -s -H 'Host: app1.com' http://192.168.56.110;
  curl -s -H 'Host: app2.com' http://192.168.56.110;
  curl -s http://192.168.56.110
"
```

## 6. Run p3

p3 has no `Vagrantfile` of its own (by design — see the subject's expected
submission structure on page 17). It still needs to run inside *a* VM, so
bring up one more plain VM the same way p1/p2 do, then run p3's own scripts
inside it. Nothing in `p3/scripts/` is p1/p2-specific — `install_dependencies.sh`
installs Docker/kubectl/k3d wherever it's run, and `setup.sh` builds the k3d
cluster + Argo CD from there.

At home this was validated with a throwaway Vagrantfile (not committed —
p3 legitimately has none). At school, either reuse the same pattern (a
one-off `vagrant init ubuntu/jammy64` + `vagrant up` in a scratch directory)
or, if your reading of the "done in a VM" rule allows it, run
`p3/scripts/setup.sh` directly on the bare host, which already has
Docker preinstalled. Whichever VM you use:

```bash
# inside that VM (or via its synced folder):
cd p3/scripts
./setup.sh
```

Then verify per `README.md`'s "Part 3" usage section (`kubectl get pods -n
argocd`, `kubectl get applications -n argocd`, `kubectl get pods -n dev`).

**Before the demo, confirm the GitHub repo is actually public** — Argo CD
clones it over plain HTTPS with no credentials, and the subject requires a
public repo for p3 anyway. If `kubectl get applications -n argocd` shows
`SYNC STATUS: Unknown` and `kubectl get pods -n dev` is empty, that's almost
certainly this (or the repo URL being wrong — see `TROUBLESHOOTING.md`).

**If you fix `argocd-app.yaml` after the `Application` already exists in
the cluster, re-apply it** (`kubectl apply -f p3/confs/argocd-app.yaml`, or
just re-run `setup.sh`) — Argo CD does not retroactively pick up spec
changes made to the file on disk; it only re-syncs the *target* manifests
against Git, not its own `Application` object.

## 7. Run the bonus (local GitLab)

Only relevant if the mandatory part (p1+p2+p3) is fully working — the
subject only evaluates the bonus if the mandatory part is flawless.

```bash
cd ../bonus
../scripts/vagrant-wrapper.sh up
```

This is a single, heavier VM (10GB RAM, 4 CPU — GitLab's Helm chart needs
real headroom even trimmed down) and takes 10-15 minutes: Postgres/Redis/
MinIO, then the GitLab Helm chart itself, then it seeds a `root/playground`
project and wires Argo CD to it. **Don't run this at the same time as
bringing up p1** — see the memory-pressure note below.

```bash
../scripts/vagrant-wrapper.sh ssh -c "
  kubectl get applications -n argocd
  kubectl get pods -n dev
"
```

To prove the mandatory p3 flow also works unchanged in this same VM/cluster:

```bash
../scripts/vagrant-wrapper.sh ssh -c "GIT_SOURCE=github ./scripts/setup.sh"
```

(needs the folder re-synced/re-run from `/vagrant`, see `bonus/scripts/setup.sh`
for exactly what `GIT_SOURCE` switches).

## 8. Cleanup between attempts

```bash
cd p1 && ../scripts/vagrant-wrapper.sh destroy -f
cd ../p2 && ../scripts/vagrant-wrapper.sh destroy -f
cd ../bonus && ../scripts/vagrant-wrapper.sh destroy -f
# + destroy whatever throwaway VM you used for p3
```

Destroying and re-`up`-ing is the fastest way to get back to a clean state
if something looks wrong mid-defense — every fix in this project lives in
`Vagrantfile`/`scripts/`, not in manual steps taken after boot.

## Watch host memory across all of this

Running p1's 2 VMs, p2's VM, a p3 VM, and bonus's heavy GitLab VM
*simultaneously* pushed this project's home test machine (31GB RAM) down to
~1GB "available" — at that point, **p1's worker join failed with a
misleading "not authorized" error that looked like a config bug but was
actually the k3s agent's TLS handshake getting starved of resources** (see
TROUBLESHOOTING.md). The fix wasn't waiting or freeing memory after the
fact — the wedged agent didn't self-heal — it was destroying and recreating
both p1 VMs once memory was actually free again. Check `free -h` (want
several GB "available") and `VBoxManage list runningvms` before bringing up
another part if previous ones are still running from earlier testing; halt
or destroy what you don't need concurrently.
