# iot-base VM — full VirtualBox configuration reference

This documents exactly how the `iot-base` VM was built at school, so you can
reproduce the same environment at home. It's a personal reference, not part
of the graded repo.

> **Superseded (2026-09-02): the project now uses Option B, with no-sudo
> Vagrant.** Testing at home proved that double-nesting (Option A, this
> file) is unreliable — see `info/iot-base-home-setup-log.md` for the full
> story, ending in a genuine CPU-level triple fault under nested
> virtualization. Separately, the school account turning out to have **no
> sudo at all** ruled out Option B's `sudo apt install vagrant` as written
> below too. The actual working setup is single-level virtualization (no
> wrapper VM) with Vagrant installed **without sudo** via
> `scripts/vagrant-install-nosudo.sh` + `scripts/vagrant-wrapper.sh`. See
> `info/school-machine-checklist.md` for the exact steps to follow at
> school. This file is kept only as a historical record of Option A.

## Before you replicate: one important decision

At school, `iot-base` exists only because the student account has **no
sudo** on the bare host and Claude Code runs inside a **Flatpak sandbox**
there — so a wrapper VM was the only way to get "the whole project done in a
VM" as the subject requires, while still needing Vagrant/VirtualBox *inside*
that wrapper for p1/p2 (double nesting: your PC → `iot-base` → `jhogoncaS`/
`jhogoncaSW`).

**That double nesting is also the suspected cause of the unresolved bug in
`TROUBLESHOOTING.md`** (the K3s agent can't complete its TLS handshake with
the server). At home you almost certainly have real admin rights on your own
machine, so you have a real choice:

- **Option A — exact replication** (below): build `iot-base` the same way,
  then run p1/p2's Vagrant inside it. Useful if you want to keep
  investigating that exact bug, or want your home setup to match the school
  one 1:1 for defense rehearsal.
- **Option B — skip the wrapper**: install VirtualBox + Vagrant directly on
  your home machine (`sudo apt install virtualbox`, HashiCorp's repo for
  Vagrant — see `scripts/bootstrap.sh` in the repo) and run p1/p2 straight
  from there. Only **one** level of virtualization (your PC → `jhogoncaS`/
  `jhogoncaSW`), which should sidestep the nested-networking bug entirely.
  p1/p2 already satisfy "done in a VM" on their own; p3 just needs Docker/K3d
  running somewhere — a single VM (or none, if your policy reading allows
  running it directly) works.

If your goal is "get a working demo," B is faster and more likely to just
work. If your goal is "reproduce and fix the exact bug," use A.

---

## Option A — exact `iot-base` replication

### Base image

Ubuntu 22.04 (Jammy) **server cloud image**, not a Vagrant box — this is a
real VM built by hand with `VBoxManage` + `cloud-init`, no installer/ISO
interaction needed:

```bash
curl -fsSL -o jammy-server-cloudimg-amd64.vmdk \
  https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.vmdk
```

### Disk: clone to VDI and grow it

The cloud image is small by default; clone it to a resizable VDI and grow it
to 60 GB (cloud-init's `growpart`/`resizefs` modules expand the filesystem
to fill it automatically on first boot — no manual partitioning needed):

```bash
VBoxManage clonemedium jammy-server-cloudimg-amd64.vmdk iot-base-disk.vdi --format VDI
VBoxManage modifymedium iot-base-disk.vdi --resize 61440   # MB = 60 GB
```

### cloud-init seed (first-boot config)

Two files, then packed into an ISO cloud-init reads on first boot.

`user-data` — **note the `groups: [sudo]` only**. An earlier attempt added
`docker` to the initial groups list, but Docker isn't installed yet at that
point, so `useradd` fails on the unknown group and the *whole* user creation
silently doesn't happen (no error surfaced — the symptom was just "SSH key
never works"). Add the user to `docker` later, after installing Docker.

```yaml
#cloud-config
hostname: iot-base
manage_etc_hosts: true
users:
  - default
  - name: jhogonca
    gecos: jhogonca
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys:
      - ssh-rsa AAAA...your-public-key... you@yourhost
chpasswd:
  list: |
    jhogonca:CHANGE_ME
  expire: false
ssh_pwauth: true
package_update: true
```

Replace the `ssh_authorized_keys` entry with your own `~/.ssh/id_rsa.pub` (or
whichever key you want to use), and change the password. The password is a
deliberate fallback: if SSH ever breaks, you can still log in via the
VirtualBox console window.

`meta-data`:

```yaml
instance-id: iot-base-001
local-hostname: iot-base
```

Build the seed ISO (volume label **must** be `CIDATA`, case as shown):

```bash
xorriso -as genisoimage -output seed.iso -volid CIDATA -joliet -rock user-data meta-data
```

(`xorriso` ships by default on most distros; `genisoimage`/`cloud-localds`
work too if you have them instead.)

### Create and configure the VM

```bash
VBoxManage createvm --name "iot-base" --ostype "Ubuntu_64" --register
# (school used --basefolder to point at a bigger disk than $HOME — only
# needed if your home disk is similarly tight on space)

VBoxManage modifyvm iot-base \
  --memory 8192 \
  --cpus 4 \
  --nested-hw-virt on \
  --nic1 nat \
  --natpf1 "ssh,tcp,127.0.0.1,2222,,22" \
  --audio-driver none \
  --graphicscontroller vmsvga \
  --boot1 disk --boot2 dvd --boot3 none --boot4 none

VBoxManage storagectl iot-base --name "SATA" --add sata --controller IntelAHCI
VBoxManage storageattach iot-base --storagectl "SATA" --port 0 --device 0 --type hdd --medium iot-base-disk.vdi

VBoxManage storagectl iot-base --name "IDE" --add ide
VBoxManage storageattach iot-base --storagectl "IDE" --port 0 --device 0 --type dvddrive --medium seed.iso
```

**`--nested-hw-virt on` is the critical flag** — without it, VirtualBox
running *inside* this VM (for p1/p2) won't have hardware virtualization and
will refuse to boot 64-bit guests. Your CPU needs to support nested VT-x/
AMD-V for this to actually work; check first:

```bash
VBoxManage list hostinfo | grep -i "nested"
# should say: Processor supports nested HW virtualization: yes
```

Memory/CPU (8 GB / 4 vCPU) needs to leave headroom for p1's two inner VMs
(1 GB + 512 MB) plus p2's VM (1 GB) plus Docker/k3d for p3, all running
*inside* this one. Give it more if your home machine has the RAM to spare —
6 GB caused the K3s agent's `systemctl start` to hang indefinitely under
memory pressure before it was bumped to 8 GB (unrelated to the still-open
networking bug, but real and worth avoiding).

If port 2222 is already taken on your home machine (unlikely, but check
`ss -tln | grep 2222` first), just change the `natpf1` host port and adjust
the `ssh -p` calls below accordingly — that's literally what happened at
school (something else already had 2222, forwarded traffic silently went
nowhere, and it took a while to figure out the SSH client was never even
reaching this VM).

### Boot and connect

```bash
VBoxManage startvm iot-base --type headless
# wait ~30-60s for cloud-init to finish, then:
ssh -p 2222 jhogonca@127.0.0.1
```

### Inside iot-base: install VirtualBox + Vagrant

Once logged in (real sudo available here, unlike the school's bare host),
just use `scripts/bootstrap.sh` from the repo — it installs git, VirtualBox,
and Vagrant via HashiCorp's official apt repo, and checks nested
virtualization is actually visible before doing anything:

```bash
git clone <your-repo-url>
cd <repo>
./scripts/bootstrap.sh
cd p1 && vagrant up
```

p3's own dependencies (Docker, kubectl, k3d) install automatically via
`p3/scripts/install_dependencies.sh` when you run `p3/scripts/setup.sh`.

---

## Option B — skip the wrapper (recommended if you're not chasing the bug)

On your home machine directly (assuming you have sudo there):

```bash
sudo apt update
sudo apt install -y virtualbox git
# Vagrant via HashiCorp's repo — see scripts/bootstrap.sh in the repo for
# the exact commands (adds their apt key + repo, then apt install vagrant)

git clone <your-repo-url>
cd <repo>
cd p1 && vagrant up
```

No nested virtualization involved at all, so `config.vm.boot_timeout` in
`p1/Vagrantfile` can probably go back down from 600s if you want (not
required — it's harmless either way).
