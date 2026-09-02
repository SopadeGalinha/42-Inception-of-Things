# info/

Personal reference material, not part of the graded repo — remove this
folder before submission.

## iot-base/ — emergency fallback wrapper VM

The project's normal setup runs p1, p2, p3, and the bonus each directly on
the bare host, one Vagrant VM (or k3d cluster) per part, no wrapper — see
the repo root `README.md` and `TROUBLESHOOTING.md` for why (double-nested
virtualization was tried first and proved unreliable; the school machine
also has no `sudo`, which the root `scripts/vagrant-wrapper.sh` works
around directly on the bare host).

`iot-base/` exists only in case that direct approach is somehow blocked at
school and a full-sudo wrapper VM is genuinely needed as a fallback. It's a
plain Vagrant VM with nested hardware virtualization enabled and its own
VirtualBox + Vagrant install (real `sudo` inside it, so no no-sudo trickery
needed there).

**Before using it**, confirm the host CPU actually supports nested
virtualization:

```bash
VBoxManage list hostinfo | grep -i nested
# must say: Processor supports nested HW virtualization: yes
```

**To use it:**

```bash
cd info/iot-base
../../scripts/vagrant-wrapper.sh up      # or plain `vagrant up` if sudo is available
../../scripts/vagrant-wrapper.sh ssh
```

Once inside, `git clone` the project and run p1/p2/p3/bonus from there,
exactly as documented in the repo root `README.md` — real `sudo` is
available inside this VM, so `scripts/bootstrap.sh` works as-is too.

**To tear it down:**

```bash
cd info/iot-base
../../scripts/vagrant-wrapper.sh destroy -f
```
