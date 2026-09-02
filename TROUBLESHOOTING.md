# Troubleshooting log — p1 worker join failure

## RESOLVED (2026-09-01, tested at home): root cause was VM memory, not networking

Everything below this note was the investigation as it stood after the
school session — nested virtualization was the leading hypothesis, and a
lot of real effort went into NIC offload/MTU workarounds. All of that
turned out to be a red herring. Reproducing the exact same symptom at home
on a single, non-nested VM (bare-metal VirtualBox, no wrapper) made the
real cause obvious:

**`jhogoncaS`'s 1024MB memory budget (matching the subject's "1 CPU / 512MB
(or 1024)" advice) is not enough for the current `k3s` stable release.**
`free -h` showed ~13MB "available", `kswapd0` actively thrashing, and load
average 3.39 on a single vCPU. Under that pressure, `k3s-server`'s *own*
internal calls to itself over loopback (`127.0.0.1:6444`, no network device
involved at all) were timing out and its SQL layer (kine/SQLite) logged
"Slow SQL" queries taking 26+ seconds. The worker's "failed to get CA
certs... context deadline exceeded" was simply the server being too
starved to answer in time — not a dropped or corrupted packet anywhere.

The subject's screenshots run `v1.21.4+k3s1` (CentOS-based, ca. 2021); the
`get.k3s.io` install script this project uses pulls whatever is currently
"stable" (`v1.36.4+k3s1` as of this writing), which is meaningfully
heavier. The advised 512MB/1024MB budget was sized for the old release, not
the one actually being installed.

**Fix:** bump `p1/Vagrantfile` memory to 2048MB (server) / 1024MB (worker).
Confirmed fix: `vagrant up` completed clean, `kubectl get nodes` showed
both `jhogoncaS` and `jhogoncaSW` `Ready`, and `free -h` on the server
settled at ~628MB available with no more swapping/thrashing.

**p2 needed the same fix** (bumped its single VM from 1024MB to 2048MB) —
confirmed working end to end: `kubectl get nodes` shows the node `Ready`,
all 4 pods (app1, 3x app2, app3) `Running`, `free -h` settled at ~958MB
available, and Ingress routing by `Host` header works correctly
(`app1.com` → app1, `app2.com` → app2, no/unknown host → app3 default).
One transient gotcha, not a real bug: right after `k3s` finishes installing,
Traefik's own pod takes a extra ~15-20s past `kubectl wait --for=condition=Available
deployment/...` to become `Ready` (it's a separate Helm-installed
`Deployment`, not one of `setup.sh`'s own `kubectl wait` targets) — a `curl`
fired immediately after `vagrant up` finishes can get "Connection refused"
on port 80 for a few seconds. It resolves on its own; no fix needed, just
don't demo the `curl` test in the same breath as `vagrant up` finishing.

**p3 needed no fix** — K3d + Argo CD have no VM memory sizing to get wrong in
the first place (they run in Docker, not a k3s-on-bare-metal VM), and were
tested successfully in a throwaway single VM (4096MB/2 CPU, generous
headroom — not tuned down to a minimum since p3 has no prescribed VM sizing
in the subject). One real gotcha found: `install_dependencies.sh` adds the
current user to the `docker` group, but that only takes effect on a **new
login session** — running `setup.sh` immediately after a fresh
`install_dependencies.sh` in the *same* shell fails at the `docker info`
check with "Docker was installed but the daemon isn't reachable yet." A
fresh `vagrant ssh` (or `newgrp docker`) before re-running `setup.sh` fixes
it, exactly as the script's own error message says. At the school, if
Docker is genuinely preinstalled (as `TROUBLESHOOTING.md`'s Environment
section assumes), the user is presumably already in the `docker` group and
this won't come up at all — it's an artifact of testing on a from-scratch
VM.

Two more real bugs found and fixed while validating p3 at home:

1. **Argo CD's official install manifest is too large for a client-side
   `kubectl apply`**: `install_argocd()` failed with `The
   CustomResourceDefinition "applicationsets.argoproj.io" is invalid:
   metadata.annotations: Too long: may not be more than 262144 bytes`. The
   `kubectl.kubernetes.io/last-applied-configuration` annotation a
   client-side apply writes exceeds the 256KiB annotation limit once you
   include the whole (huge) ApplicationSet CRD. **Fix:** `p3/scripts/setup.sh`
   now applies with `--server-side --force-conflicts` instead.
2. **`p3/confs/argocd-app.yaml` pointed at the wrong GitHub repo name**
   (`jhogonca-Inception-of-Things`, which doesn't exist — the real one is
   `42-Inception-of-Things`, per `git remote -v`). Argo CD's Application sat
   at `SYNC STATUS: Unknown` forever and nothing ever landed in the `dev`
   namespace. Fixed the URL in both `argocd-app.yaml` and `README.md`.
3. **The (now-correct) repo is currently private** — `git ls-remote` over
   SSH works, but an anonymous `curl` to the same repo over HTTPS 404s, and
   Argo CD's default `Application` clones over plain HTTPS with no
   credentials configured. The subject's own p3 text is explicit that this
   repo must be public anyway ("You must be able to change the version from
   your **public** GitHub repository"), so the fix is to make the repo
   public rather than wire up Argo CD repo credentials for a private repo.
   The bonus's local GitLab instance is a separate *additional* mirror per
   its own instructions ("Everything you did in Part 3 must work with your
   local Gitlab") — it doesn't replace the requirement that the mandatory p3
   uses a public GitHub repo.

**Confirmed fixed (2026-09-02), after making the repo public:** the
`Application` object already running in the cluster still had the *old*
broken `repoURL` baked into its `spec.source` — fixing `argocd-app.yaml` on
disk doesn't retroactively update an `Application` that already exists;
Argo CD only reconciles the *manifests the Application points at* against
Git, not its own spec. Re-`kubectl apply -f p3/confs/argocd-app.yaml` (which
is exactly what `deploy_application()` in `setup.sh` does on every run) is
what actually picks up a corrected `repoURL`/`path`. After that:
`kubectl get applications -n argocd` showed `Synced`/`Healthy`, the
`wil42-playground` pod came up in `dev`, and `curl` through a port-forward
returned `{"status":"ok", "message": "v1"}` as expected. p3 is fully
verified end to end.

The NIC offload/MTU workaround and the switch to `virtio` NICs (both
described below) are **not required** for this failure specifically — they
were a plausible-looking dead end. They're harmless to keep, and might
still matter if a *real* nested-networking scenario (e.g. an `iot-base`
style wrapper) is used again later, since that class of bug is real in
general — it just wasn't what was happening here.

### Architecture decision: no wrapper VM, no sudo needed for Vagrant

The school account has no `sudo` at all, which rules out `scripts/bootstrap.sh`'s
`apt install vagrant`. The final setup is:

- **Single-level virtualization**, straight on the bare host — no `iot-base`
  wrapper. p1 and p2 each create their own Vagrant VM(s) directly; p3 runs in
  one more VM of the same kind. This still satisfies "the whole project has
  to be done in a virtual machine" per-part, and sidesteps double-nesting
  entirely (VirtualBox is assumed preinstalled on the school host, per the
  Environment section below).
- **Vagrant installed without sudo**: the official `.deb` is a portable
  payload once extracted (`ar x` + `tar xzf`, no `dpkg`/root needed) — its
  launcher is a statically-linked Go binary that execs a bundled Ruby
  runtime via `LD_LIBRARY_PATH`, no privileged step involved anywhere in
  that chain. See `scripts/vagrant-install-nosudo.sh` and
  `scripts/vagrant-wrapper.sh`. VirtualBox's own setuid-root helpers (for
  `hostonlyif create`) are unaffected by this — they only break if driven
  from inside an unprivileged user namespace (e.g. a `bwrap` sandbox), not
  from a plain shell with a custom `LD_LIBRARY_PATH`.

Double-nested virtualization (the `iot-base` wrapper approach) was tried
first and ruled out on this hardware by a genuine CPU-level triple fault
under load — see `info/iot-base/` for a from-scratch, Vagrant-based fallback
wrapper VM kept only in case the direct approach above is somehow blocked
at school.

### New finding (2026-09-02): host-level memory pressure can make the p1
### worker fail to join with a *misleading* "not authorized" error

Bringing up p1 while 4-5 other heavy VMs were also running on the same host
(bonus's GitLab VM alone budgets 10GB) produced a **new, different**
failure: `jhogoncaSW` looped forever on

```
level=info msg="Waiting to retrieve agent configuration; server is not ready:
failed to retrieve configuration from server: not authorized"
```

This *looks* like a token mismatch, but isn't — `k3s.service.env` on both
nodes had the exact same `K3S_TOKEN`, byte-for-byte (`cat -A` checked). The
server's own logs showed **zero trace** of the agent's join attempts ever
arriving, despite plain HTTPS requests (e.g. `/cacerts`) succeeding fine
between the two nodes. At the time, host `free -h` showed ~1.2GB available
out of 31GB total, with 5 VMs running concurrently. Freeing memory (halting
one other VM) didn't fix it — the already-wedged `k3s-agent` process kept
retrying the same way. **Fully destroying and recreating both p1 VMs**
after freeing memory (~10-12GB available) fixed it immediately, first try.

**Takeaway:** on this host, don't bring up p1 while several other heavy
VMs (especially the bonus GitLab one) are already running — the join can
fail in a way that looks like a config bug but is actually host resource
starvation, and once an agent is in this state it doesn't self-heal; a full
`vagrant destroy -f && vagrant up` is the fix, not just waiting or freeing
memory after the fact. Check `free -h` (want several GB "available") and
`VBoxManage list runningvms` before starting p1 if other parts' VMs are
still up from earlier testing.

---

## Original investigation (kept for reference — root cause above supersedes it)

This documents an unresolved networking issue hit while setting up the
project on a school lab machine, so the next attempt doesn't repeat the same
dead ends. **Update: the actual root cause turned out to be unrelated — see
the RESOLVED note at the top of this file.**

## Environment

- Physical machine: bare-metal (Dell OptiPlex 7780, no outer hypervisor).
- No `sudo` for the student account on the bare host, and Claude Code's shell
  there runs inside a Flatpak sandbox — system-level work has to go through
  `flatpak-spawn --host`.
- Per the subject's "the whole project has to be done in a virtual machine"
  requirement, a base VM (`iot-base`, Ubuntu 22.04, created via VBoxManage +
  cloud-init, nested VT-x enabled) was built to hold all the work. Inside
  `iot-base`, Vagrant + VirtualBox run p1/p2's VMs — so p1's two nodes are
  **doubly nested**: bare host → `iot-base` → `jhogoncaS` / `jhogoncaSW`.

## Symptom

`jhogoncaS` (K3s server) comes up healthy on its own every time. `jhogoncaSW`
(K3s agent) boots fine and can reach `jhogoncaS` over the `192.168.56.0/24`
private network, but the agent never finishes joining the cluster. It loops
forever on:

```
level=info msg="Waiting to retrieve agent configuration; server is not ready:
failed to get CA certs: Get \"https://127.0.0.1:6444/cacerts\": context
deadline exceeded (Client.Timeout exceeded while awaiting headers)"
```

(`127.0.0.1:6444` is the agent's own local load-balancer proxy, which forwards
to `192.168.56.110:6443` — the real K3s server.)

## What was confirmed working

- ICMP between the two nodes, including large (1400-byte, `-M do`) pings —
  no packet loss, low latency.
- Plain small TCP/HTTP requests between the two nodes (tested with a
  throwaway `python3 -m http.server`).
- `k3s` is listening on the correct address (`ss` confirms
  `192.168.56.110:6443`), reachable from the server itself over that address
  (initially it wasn't — see fixes below).
- No firewall involved: `ufw` is inactive, `iptables` INPUT policy is
  `ACCEPT` with only the standard kube-router chains.
- Vagrant's own boot-time SSH check succeeds after raising
  `config.vm.boot_timeout` to 600s — the extra time was a real, separate
  issue (nested virtualization boots noticeably slower), now fixed.

## Fixes applied (both are real fixes for a known class of bug, but did not
## fully solve this specific failure)

Both are baked into `p1/scripts/setup_server.sh` and
`p1/scripts/setup_worker.sh`, applied on the private-network interface and
reapplied on every boot via a `disable-nic-offload.service` systemd unit
(ethtool settings and MTU don't persist across reboots on their own):

1. **Disable NIC checksum/segmentation offload** (`ethtool -K <iface> tx off
   rx off gso off gro off tso off`). This is the standard fix for a
   well-documented nested-virtio bug where checksums get corrupted and large
   TCP payloads silently vanish while ICMP keeps working. Applied to both
   nodes' `enp0s8`. Result: fixed a *different*, simpler symptom (the
   server couldn't originally even curl its own private IP), but the K3s
   join still failed after a full `vagrant destroy && vagrant up` with this
   in place from the very first boot.
2. **Lower the interface MTU to 1400** (`ip link set dev <iface> mtu 1400`),
   a common companion fix for PMTU black holes across nested virtual NICs.
   Applied to both nodes alongside the offload fix, again from a full clean
   rebuild. No change in the outcome.

## Current hypothesis

The failure is specific to the larger, multi-round-trip mTLS exchange the
K3s agent performs (CA cert retrieval, client cert issuance) — small
requests and raw ICMP work, but this specific traffic pattern between the
two doubly-nested VMs does not. This looks like a deeper limitation of
VirtualBox's virtual networking under two levels of nesting (bare host →
`iot-base` → inner VM) rather than something `ethtool`/MTU tuning alone can
paper over. It was not root-caused before running out of time in this
session.

## Things worth trying next

- **Packet capture during a real join attempt**: run `tcpdump` on
  `jhogoncaSW`'s `enp0s8` while it retries, and see whether the TLS
  handshake even completes or whether it's a specific later record that
  never arrives/acks.
- **Test without the double nesting**: bring up p1 directly on the bare
  host (no `iot-base` wrapper) to check whether a single level of
  virtualization is unaffected — this would confirm nesting depth as the
  root cause rather than something in the Vagrantfile/scripts themselves.
- **Upgrade VirtualBox inside `iot-base`**: it currently runs whatever
  Ubuntu 22.04's `apt` repo ships (6.1.x via `virtualbox-dkms`/`virtualbox`
  packages) rather than the latest release from Oracle's own repo. Nested
  networking bugs have been fixed across VirtualBox versions before.
- **Reconsider whether the `iot-base` wrapper is required at all** for this
  specific lab machine. It exists to satisfy "the whole project has to be
  done in a virtual machine," but if the tradeoff (a hard-to-diagnose nested
  networking bug) turns out to be a dead end, running p1/p2 directly on the
  bare host (which already has VirtualBox and Docker preinstalled) is worth
  discussing as an alternative, accepting that it's a looser reading of that
  requirement.

## State left behind

- `jhogoncaS` and `jhogoncaSW` VM definitions in `p1/Vagrantfile` are
  otherwise complete and correct (box, IPs, token, boot timeout).
- `p1/scripts/setup_server.sh` and `p1/scripts/setup_worker.sh` have the
  offload/MTU workaround in place; harmless to keep even if it turns out to
  be unrelated to the real root cause.
- p2 and p3 were not attempted yet in this environment — this issue only
  blocks p1 (and would need to be resolved, or the `iot-base` wrapper
  reconsidered, before p2 can be verified inside the same nested setup).
