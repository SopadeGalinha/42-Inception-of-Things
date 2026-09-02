# iot-base VM — home replication log (2026-09-01)

Actual run log of rebuilding `iot-base` at home, following the plan in
[`iot-base-vm-config.md`](iot-base-vm-config.md) (Option A — exact
replication, chosen deliberately to keep testing the nested-networking bug
from `TROUBLESHOOTING.md` before going back to the school machine). Personal
reference, not part of the graded repo — remove before submission along with
the rest of `info/`.

## Host machine

- Arch Linux (Omarchy), kernel `7.1.9-arch1-2`, CPU: Intel Core i7-13650HX
  (EPT present — real admin rights here, unlike the school lab machine).
- VirtualBox `7.2.16r174877`.

## Blockers hit and fixes (host-level prep, not in the original doc)

1. **`vboxdrv` kernel module not loaded.** `virtualbox-host-dkms` was
   installed but `dkms status` was empty — the module had never been built.
   Root cause: `linux-headers` (7.1.9) was ahead of the running kernel
   package `linux` (7.1.8) after a partial update, so dkms had no matching
   headers to build against.
   - Fix: `omarchy update` (this system wraps `pacman` — direct `sudo pacman
     -Syu` is blocked and tells you to use `omarchy update` instead) to sync
     kernel + headers, then reboot. After reboot, `dkms status` showed
     `vboxhost/7.2.16_OSE` built and `vboxdrv` loaded automatically.
   - Confirmed after: `VBoxManage list hostinfo` reports both "Processor
     supports nested paging: yes" and "Processor supports nested HW
     virtualization: yes".
2. **`xorriso` missing** (needed to build the cloud-init seed ISO). Not a
   separate package on Arch — it ships as part of `libisoburn`:
   `sudo pacman -S libisoburn`.

No other host packages were needed — `vagrant` is only installed *inside*
`iot-base`, not on the bare host, since the host's only job is running
VirtualBox to hold the wrapper VM.

## Build

Followed `iot-base-vm-config.md` Option A verbatim, with these actual values
(build artifacts — VMDK/VDI/seed.iso — live in a scratch dir outside the
repo, not committed):

- SSH key: home machine's `~/.ssh/id_ed25519.pub` (different key than
  whatever was used at school — added fresh to `user-data`).
- Fallback console password for `jhogonca`: `BoaxvHrEwR3UOVSc` (local-only,
  NAT-forwarded loopback access; rotate or drop this file before
  submission).
- Disk grown to 60GB as in the doc (home disk has ~900GB free, no need to
  economize).
- VM UUID: `19f324c4-370a-4d0e-be6f-4b55bedb3608`.
- NAT SSH forward: host port 2222 (was free, no clash like at school).

No deviations from the documented `VBoxManage createvm`/`modifyvm`/
`storagectl`/`storageattach` commands.

## Verified after boot

```
$ ssh -p 2222 jhogonca@127.0.0.1
Static hostname: iot-base
Operating System: Ubuntu 22.04.5 LTS
Kernel: Linux 5.15.0-190-generic
Virtualization: oracle
$ df -h /          # 58G, growpart/resizefs worked
$ grep -Eo 'vmx|svm' /proc/cpuinfo   # vmx visible inside the guest — nested
                                     # HW virt is correctly exposed to it
$ sudo -n whoami    # root — passwordless sudo confirmed
```

`cloud-init status --wait` returned `done` with no errors.

## Repo copied in, bootstrap run

Repo was `rsync`'d into `~/42-Inception-of-Things` inside `iot-base` (private
GitHub repo, no deploy key set up there, so this was simpler than auth).
`scripts/bootstrap.sh` ran cleanly: VirtualBox `6.1.50_Ubuntu` (from Ubuntu's
own apt repo, matching what the original doc predicted) and Vagrant `2.4.9`.

## `vagrant up` (p1) — three attempts, escalating findings

**Attempt 1** (before touching anything inside `iot-base`): failed while
Vagrant was "Configuring and enabling network interfaces..." for `jhogoncaS`
(i.e. right when it creates the VirtualBox hostonly adapter inside
`iot-base`). The *outer* SSH session (physical host → `iot-base`, port 2222)
died — raw TCP connected instantly but zero bytes (not even the SSH banner)
ever arrived. Confirmed with a raw `/dev/tcp` probe. This is the exact
"tiny/zero-payload packets work, anything carrying real data doesn't"
signature already known from `TROUBLESHOOTING.md`, except this time on
`iot-base`'s own NAT-facing interface (`enp0s3`), not on p1's private
network.

  - Fix applied: same offload-disable + MTU 1400 workaround as p1's nodes,
    applied to `iot-base`'s own `enp0s3`, made persistent via the same
    `disable-nic-offload.service` pattern (see [Blockers hit and
    fixes](#blockers-hit-and-fixes-host-level-prep-not-in-the-original-doc)
    section above — this was done as an ad hoc SSH command, not committed to
    any script since `iot-base` itself isn't part of the graded repo).

**Attempt 2** (with the `iot-base`-side fix in place): got much further —
`jhogoncaS` booted, provisioning ran, `setup_server.sh` started downloading
the K3s binary — then the connection Vagrant uses to run the *inline*
provisioner (which also rides `jhogoncaS`'s own NAT adapter, since that's
the route to the internet) died mid-download with "The SSH connection was
unexpectedly closed by the remote end." Root cause: `setup_server.sh`/
`setup_worker.sh` only ever applied the offload/MTU fix to the
*private-network* interface (matched by IP), never to the node's own NAT
interface — so the K3s binary download (a real multi-megabyte transfer)
hit the same corruption bug on the interface nobody had patched yet.

  - Fix applied: generalized `p1/scripts/setup_server.sh` and
    `setup_worker.sh` to loop over **every** non-loopback interface, not
    just the one carrying the private IP. Committed to the repo (this part
    *does* belong in the graded p1 folder).

**Attempt 3** (with the generalized script fix): failed even earlier —
`jhogoncaS` never got past "Warning: Connection reset. Retrying..." during
Vagrant's own initial SSH handshake, and eventually hit the 600s
`boot_timeout`. A screenshot of `jhogoncaS`'s console (via `VBoxManage
controlvm ... screenshotpng`, since guest additions/network weren't up yet
for `guestcontrol`) showed it frozen mid-boot at systemd's "File System
Check on Root Device..." step — two screenshots 20s apart were pixel
identical. Worse: **`iot-base` itself then stopped responding entirely**.
Its own console showed repeated `e1000 0000:00:03.0 enp0s3: Reset adapter`
messages, and two more screenshots of *`iot-base`'s* console, several
minutes apart, showed an **identical, frozen kernel uptime counter**
(`51.331281`) while the outer host's `VBoxHeadless` process for `iot-base`
sat pinned at ~100% CPU. That combination (frozen guest clock + pegged host
CPU) is a genuine kernel-level livelock, not just a slow or dropped
connection — recovered only with a hard `VBoxManage controlvm iot-base
poweroff` + `startvm` from the physical host.

## Assessment

This goes beyond the specific K3s-join bug `TROUBLESHOOTING.md` describes.
That bug was "large TLS handshakes silently vanish, small requests are
fine." What attempt 3 surfaced is a second, more severe failure mode:
**the emulated e1000 NIC itself can enter a reset loop and livelock the
entire guest under load, at any level of this nesting stack** (it happened
to `iot-base`'s own NAT interface, not just to a p1 node). Both failure
modes point the same direction: this specific combination (VirtualBox
7.2.16 host running a nested-hw-virt guest, itself running VirtualBox
6.1.50 for further guests) has a fundamentally unreliable virtual
networking stack under load, on both the school machine and this one —
different hardware/VirtualBox versions, same family of symptom. This is
stronger evidence that the instability is inherent to double nesting itself
rather than something host-specific that home admin rights could route
around.

**Decision point:** asked the project owner whether to switch to Option B or
keep investigating Option A — chose to keep investigating.

## Attempt 4 — switched `iot-base` and the p1 nodes to virtio-net

Changed `iot-base`'s own `--nictype1` from the default `e1000` to `virtio`
(`VBoxManage modifyvm iot-base --nictype1 virtio`), and added
`vb.customize ["modifyvm", :id, "--nictype1", "virtio", "--nictype2",
"virtio"]` to both node definitions in `p1/Vagrantfile` (committed — this
part is a real, generally-useful improvement to the graded repo, not just a
home workaround).

Result: **big improvement on the networking front** — the K3s binary
download that killed attempt 2 completed cleanly this time, `k3s` installed,
and the systemd unit started. No more `e1000: Reset adapter` messages
anywhere, and — importantly — `iot-base` itself stayed up the whole time
(no repeat of the attempt-3 livelock). So virtio-net does look like a
genuine fix for the checksum/reset class of bug, at least for `iot-base`'s
own interface.

But provisioning still failed, this time with a different and more serious
error: the SSH connection died again right as `[INFO] systemd: Starting
k3s` printed, and `VBoxManage showvminfo` showed `jhogoncaS`'s VM state as
**`gurumeditation`** — a hypervisor-level crash, not a guest OS hang.
`jhogoncaS`'s own `VBox.log` confirms it precisely:

```
00:00:58.968619 Console: Machine state changed to 'GuruMeditation'
00:00:58.969219 !! VCPU0: Guru Meditation 1155 (VINF_EM_TRIPLE_FAULT)
00:00:58.971436 0000 - read error rc=VERR_PAGE_TABLE_NOT_PRESENT GCAddr=fffffe345499f000
```

A **triple fault** in `jhogoncaS`'s virtual CPU, immediately followed by a
wall of `VERR_PAGE_TABLE_NOT_PRESENT` errors — a nested-page-table walk
failure at the exact moment `containerd`/`k3s` started doing real container
runtime work (more demanding on CPU virtualization than booting or plain
networking). This lines up exactly with something noted way back at the
start of this log and dismissed too quickly at the time: `VBoxManage list
hostinfo` **run from inside `iot-base`** reports "Processor supports nested
paging: yes" but **"Processor supports nested HW virtualization: no."**
That flag is specifically about whether `iot-base` can reliably provide
hardware-accelerated virtualization to *its own* guests (`jhogoncaS`/
`jhogoncaSW`) — exactly the thing that just crashed.

## Revised assessment

This is no longer a networking tuning problem. A CPU-level triple fault
inside the inner VM, triggered by real container-runtime workload, is
evidence that the second level of hardware-accelerated virtualization
(VirtualBox-inside-`iot-base` accelerating `jhogoncaS` via nested VT-x) is
not reliably functional on this CPU/VirtualBox combination — matching what
the host itself already reported. Networking fixes (offload/MTU, e1000 →
virtio) got much further and are worth keeping regardless, but they can't
fix a hypervisor-level CPU fault. Realistic remaining options for Option A:
retry and hope it doesn't recur (triple faults from imperfect nested-EPT
support are often intermittent, so it might work on a later attempt, but
that's not something to rely on for a demo or a defense), or accept this as
the practical ceiling of double nesting on this hardware and fall back to
Option B for an actually-reliable home environment.

## Handy commands

```bash
VBoxManage startvm iot-base --type headless
VBoxManage controlvm iot-base acpipowerbutton   # graceful shutdown
ssh -p 2222 jhogonca@127.0.0.1
```
