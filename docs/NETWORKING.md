# Machine Networking (mpd VM)

How the host laptop reaches mpd's container subnet inside the VM.

The host-side bits (WireGuard tunnel setup, route, CA trust) are
configured by the **mpd-virt** orchestrator binary (separate repo) — not
by the in-VM `mpd` binary. This document describes the topology and the
host↔VM↔containers data path; for the actual host commands see
`mpd-virt`'s own documentation.

## Topology

```text
Laptop (macOS — primary)
  |
  | WireGuard tunnel  (10.164.0.0/30 point-to-point)
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

The VM runs `net.ipv4.ip_forward=1` so packets from the laptop transit
the VM and reach containers via `podman1`.

## How the laptop reaches containers

mpd VM uses **WireGuard** between the laptop and the VM:

- Tunnel point-to-point on `10.164.0.0/30` (Mac side `.1`, VM side `.2`).
- `AllowedIPs` on the Mac peer includes `10.163.0.0/24` so the full
  container subnet routes through the tunnel.
- `DNS = 10.163.0.3` (dnsmasq) is set in the tunnel config, so
  `*.mpd.test` resolves through the tunnel when it's up.
- mpd's local CA is installed in the host's system trust store
  (one-time at setup) so HTTPS just works.

WireGuard.app on macOS owns the route + DNS while the tunnel is up.
**No `/etc/resolver/` file, no `sudo route add` step** — toggling the
tunnel from WireGuard.app is the whole UX after first-time setup.

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

## SSH access to runtime containers

Two parallel paths, both fine:

**Via WireGuard tunnel** — direct container reachability while the
tunnel is up:

```
ssh user@php.runtime.mpd.test
```

**Via SSH ProxyJump through the VM** — works whether or not WG is up,
since the VM's address is reachable via the hypervisor's own network:

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
