# Machine Networking (mpd VM)

How the host laptop reaches mpd's container subnet inside the VM.

The host-side bits (static route, scoped DNS, CA trust) are configured
by the **mpd-virt** orchestrator binary (separate repo) — not by the
in-VM `mpd` binary. This document describes the topology and the
host↔VM↔containers data path; for the actual host commands see
`mpd-virt`'s own documentation.

## Topology

```text
Laptop (macOS — primary)
  |
  | hypervisor network + static route:  10.163.0.0/24 → <VM IP>
  |
VM (Debian Trixie)              hostname: mpd-<octet>
  |
  Podman (rootful) bridge:  podman1  10.163.0.1/24
   |
   `mpd-internal` Podman network    10.163.0.0/24
     |
     +-- mpd-service-dnsmasq     10.163.0.3   (DNS for *.mpd.test)
     +-- mpd-service-portal      10.163.0.4   (HTTPS read-only status)
     +-- mpd-service-fileaccess  10.163.0.5   (data-volume podman-exec target;
     |                                          SSH/scp endpoint for /srv/backups/)
     +-- mpd-service-adminer     10.163.0.6   (proxied via portal)
     +-- DB containers           10.163.0.30–.99
     +-- runtime containers      10.163.0.100+ (full dev access via SSH)
```

The VM runs `net.ipv4.ip_forward=1` (set by `bootstrap/30-networking.sh`)
so packets from the laptop transit the VM and reach containers via
`podman1`.

## How the laptop reaches containers

There is no tunnel. The laptop already reaches the VM over the
hypervisor's own network (Parallels Shared, libvirt default, Hyper-V
Default Switch), and the container subnet hangs off that:

- **Route** — `10.163.0.0/24` via the VM's IP, installed on the host by
  `mpd-virt` (persistent where the OS supports it; re-asserted on
  `start` otherwise). This is what makes container IPs reachable.
- **DNS** — a *scoped* resolver entry pointing `*.mpd.test` at dnsmasq
  (`10.163.0.3`): `/etc/resolver/mpd.test` on macOS, an NRPT rule on
  Windows, a systemd-resolved drop-in with `Domains=~mpd.test` on
  Linux. Scoped, so only `.mpd.test` queries go to the VM — everything
  else keeps using the host's normal resolvers.
- **Trust** — mpd's local CA is installed in the host's system trust
  store (one-time at setup) so HTTPS just works.

Those three facts are the whole client contract, and they're identical
on macOS, Linux, and Windows. A scoped route plus scoped DNS coexists
cleanly with a corporate VPN; nothing has to be toggled on or off to
use mpd.

## DNS forwarding upstream

dnsmasq inside the container sets `local=/mpd.test/` (so it's authoritative
for `*.mpd.test` and never forwards those queries) and reads upstream
resolvers from a bind-mounted view of the host's
`/run/systemd/resolve/resolv.conf` — the *real* per-link upstream nameservers
managed by systemd-resolved, **not** the `127.0.0.53` stub that
`/etc/resolv.conf` points at. dnsmasq watches that file and adapts when the
host switches networks (corporate VPN, Wi-Fi, etc.) without restart.

There is no `MPD_DNS_UPSTREAM` to configure and no hardcoded public DNS in
the path: queries follow whatever the host's link manager (NetworkManager
or systemd-networkd) hands to systemd-resolved.

## DNS authoritativeness

dnsmasq is **authoritative** for `*.mpd.test`. Unknown names in that domain
return NXDOMAIN immediately, AAAA queries on names with only A records
return NoData. This avoids the upstream-forwarding stalls that previously
caused multi-second `getaddrinfo` delays when AAAA queries leaked to public
DNS for `.test` TLD names.

## Diagnostic record: `vm.service.mpd.test`

In addition to the runtime / service / project records, dnsmasq serves
one special record:

```
vm.service.mpd.test → <MPD_VM_IP from /var/lib/mpd/conf/platform.env>
```

i.e. the **VM's own static IP** (e.g. `10.211.55.125` for a managed VM),
not a container subnet address. It's written as `host-record=...` in
`services.conf` by `Mpd.Service.Dnsmasq.ensureServiceDNSRecords()` and
skipped on sandbox VMs (where `MPD_VM_IP` is empty).

The purpose is identity verification: `mpd-virt diag` on the Mac queries
this name and compares the answer to the VM's known IP. A match proves
the Mac is talking to **this specific VM's** dnsmasq — not some other
resolver that happens to know about `*.mpd.test` (e.g. when juggling
multiple VMs and the host route points at the other one).

## SSH access to runtime containers

Two parallel paths, both fine:

**Direct** — container names resolve and container IPs route, so:

```
ssh user@php.runtime.mpd.test
```

**Via SSH ProxyJump through the VM** — works even without host-side
route/DNS config, since the VM's address is reachable via the
hypervisor's own network:

```
# ~/.ssh/config:
Host mpd-<octet>-php
    HostName php.runtime.mpd.test
    User user
    ProxyJump mpd-<octet>
```

IDEs (PHPStorm Gateway, VS Code Remote-SSH) configure ProxyJump the same
way. mpd-virt writes these SSH config entries automatically.

mpd assumes your laptop user, VM user, and runtime user share the same
name — that's what makes the bare jump-host form work without explicit
`user@`. Set up the VM with the same account name as your laptop login.

See also: [README.md](README.md), [SECURITY.md](SECURITY.md)
