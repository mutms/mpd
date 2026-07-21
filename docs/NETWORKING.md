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
  | hypervisor network + static route:  10.163.<NNN>.0/24 → <VM IP>
  |
VM (Debian Trixie)              hostname: mpd-<NNN>
  |
  Podman (rootful) bridge:  podman1  10.163.<NNN>.1/24
   |
   `mpd-internal` Podman network    10.163.<NNN>.0/24
     |
     +-- mpd-service-dnsmasq     10.163.<NNN>.3   (DNS for *.<NNN>.mpd.test)
     +-- mpd-service-portal      10.163.<NNN>.4   (HTTPS read-only status)
     +-- mpd-service-adminer     10.163.<NNN>.6   (proxied via portal)
     +-- DB containers           10.163.<NNN>.30–.99
     +-- runtime containers      10.163.<NNN>.100+ (full dev access via SSH)
```

The VM runs `net.ipv4.ip_forward=1` (set by `bootstrap/30-networking.sh`)
so packets from the laptop transit the VM and reach containers via
`podman1`.

## How the laptop reaches containers

There is no tunnel. The laptop already reaches the VM over the
hypervisor's own network (Parallels Shared, libvirt default, Hyper-V
Default Switch), and the container subnet hangs off that:

- **Route** — `10.163.<NNN>.0/24` via the VM's IP, installed on the host by
  `mpd-virt` (persistent where the OS supports it; re-asserted on
  `start` otherwise). This is what makes container IPs reachable.
- **DNS** — a *scoped* resolver entry pointing `*.<NNN>.mpd.test` at that
  VM's dnsmasq (`10.163.<NNN>.3`): `/etc/resolver/<NNN>.mpd.test` on
  macOS, an NRPT rule for `.<NNN>.mpd.test` on Windows, a
  systemd-resolved drop-in with `Domains=~<NNN>.mpd.test` on Linux.
  Scoped, so only that VM's zone goes to that VM — everything else keeps
  using the host's normal resolvers.
- **Trust** — mpd's local CA is installed in the host's system trust
  store (one-time at setup) so HTTPS just works.

Those three facts are the whole client contract, and they're identical
on macOS, Linux, and Windows. A scoped route plus scoped DNS coexists
cleanly with a corporate VPN; nothing has to be toggled on or off to
use mpd.

## Per-VM addressing

`<NNN>` above is the VM's `MPD_VM_ID` — the last octet of its static IP
(`000` for a sandbox VM). It is the discriminator in **both** halves of
the addressing: the third octet of the container subnet, and the first
label of the DNS zone. Nothing else varies: dnsmasq is always `.3`, the
portal always `.4`, runtimes always `.100+`.

```
VM 150:  10.163.150.0/24   zone 150.mpd.test   moodle45.150.mpd.test
VM 180:  10.163.180.0/24   zone 180.mpd.test   moodle45.180.mpd.test
sandbox: 10.163.0.0/24     zone 000.mpd.test
```

This is what makes **several VMs reachable at the same time**. The host
holds one route and one resolver entry per VM; the routes are to
disjoint /24s, and the resolver entries cover disjoint domains (macOS
`resolver(5)` matches longest suffix, so per-VM files never conflict).
Under the previous flat model every VM served the same `10.163.0.0/24`,
so the host could route to only one of them at a time — regardless of
naming.

The bare `mpd.test` apex does **not** resolve, deliberately: with two
VMs up it could only mean one of them, and mpd prefers a name that fails
to a name that silently picks. `<NNN>.mpd.test` is the apex, and it
resolves to that VM's portal.

One CA covers every VM — its name constraint (`permitted;DNS.0 =
.mpd.test`) already permits arbitrary depth beneath the root domain, so
adding a VM needs no new trust operation.

Changing an existing VM's ID is not a supported operation: the Podman
network's subnet is fixed at create time, so `mpd --vm-setup` refuses when
it finds a network that disagrees with the VM's id and prints the
teardown/recreate steps.

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

dnsmasq is **authoritative** for `*.mpd.test` (the whole root domain, not
just its own zone — a VM has exactly one dnsmasq and no business
resolving another VM's zone, so NXDOMAIN for a foreign zone is the
correct in-VM answer). Unknown names in that domain
return NXDOMAIN immediately, AAAA queries on names with only A records
return NoData. This avoids the upstream-forwarding stalls that previously
caused multi-second `getaddrinfo` delays when AAAA queries leaked to public
DNS for `.test` TLD names.

## Diagnostic record: `vm.service.<NNN>.mpd.test`

In addition to the runtime / service / project records, dnsmasq serves
one special record:

```
vm.service.<NNN>.mpd.test → <MPD_VM_IP from /var/lib/mpd/conf/platform.env>
```

i.e. the **VM's own static IP** (e.g. `10.211.55.125` for a managed VM),
not a container subnet address. It's written as `host-record=...` in
`services.conf` by `Mpd.Service.Dnsmasq.ensureServiceDNSRecords()` and
skipped on sandbox VMs (where `MPD_VM_IP` is empty).

The purpose is identity verification: `mpd-virt diag` on the Mac queries
this name and compares the answer to the VM's known IP. A match proves
the Mac is talking to **this specific VM's** dnsmasq — not some other
resolver that happens to know about the zone. With per-VM subnets a
reply from `10.163.<NNN>.3` can only be that VM's dnsmasq, so this is
now a confirmation rather than a disambiguation — but it is cheap and it
catches registry IP drift on the host side.

## SSH access to runtime containers

Two parallel paths, both fine:

**Direct** — container names resolve and container IPs route, so:

```
ssh user@php.runtime.<NNN>.mpd.test
```

**Via SSH ProxyJump through the VM** — works even without host-side
route/DNS config, since the VM's address is reachable via the
hypervisor's own network:

```
# ~/.ssh/config:
Host mpd-<octet>-php
    HostName php.runtime.<NNN>.mpd.test
    User user
    ProxyJump mpd-<octet>
```

IDEs (PHPStorm Gateway, VS Code Remote-SSH) configure ProxyJump the same
way. mpd-virt writes these SSH config entries automatically.

mpd assumes your laptop user, VM user, and runtime user share the same
name — that's what makes the bare jump-host form work without explicit
`user@`. Set up the VM with the same account name as your laptop login.

See also: [README.md](README.md), [SECURITY.md](SECURITY.md)
