# Troubleshooting log — p1 worker join failure (nested virtualization)

This documents an unresolved networking issue hit while setting up the
project on a school lab machine, so the next attempt doesn't repeat the same
dead ends.

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
