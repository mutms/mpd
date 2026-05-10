# Desktop Networking (mpd-desktop)

This page describes networking for `mpd-desktop` on macOS with Podman Desktop.

Networking is split by execution mode because architecture is different between desktop and machine flows.

## Why this design exists

Podman Desktop on macOS uses `gvproxy` userspace forwarding. It forwards only explicitly published ports and does not expose container subnet routes to the host kernel.

Implications:
- `-p 127.0.0.1:8080:8080` works
- direct host access to container IPs on `mpd-internal` does not work without an extra tunnel layer
- relying only on port mappings does not scale for many runtimes using standard ports

## WireGuard container bootstrap

mpd uses a WireGuard service container as a gateway:

- container: `mpd-service-wireguard`
- fixed internal IP: `10.163.0.2`
- one host bind only: `127.0.0.1:51820/udp`

The host WireGuard peer connects to that local endpoint. After handshake, all traffic to `10.163.0.0/24` flows through the tunnel (not through `gvproxy` HTTP/TCP port forwarding).

## Subnet layout

| Subnet          | Purpose                                   |
|-----------------|-------------------------------------------|
| `10.163.0.0/24` | `mpd-internal` container network          |
| `10.164.0.0/30` | WireGuard point-to-point tunnel endpoints |

- macOS tunnel address: `10.164.0.1/32`
- WireGuard container tunnel address: `10.164.0.2/32`

## Topology

```text
Mac host
  utun / WireGuard
    10.164.0.1/32
    route 10.163.0.0/24 via tunnel
      |
      | UDP 127.0.0.1:51820
      v
Podman VM / mpd-internal
  mpd-service-wireguard  10.163.0.2 (wg0: 10.164.0.2/32)
  mpd-service-dnsmasq    10.163.0.3
  mpd-service-portal     10.163.0.4
  mpd-service-fileaccess 10.163.0.5  (data-volume podman-exec target)
  mpd-service-adminer    10.163.0.6  (proxied via portal)
  DBs                    10.163.0.30–.99
  runtimes               10.163.0.100+
```

## DNS on macOS

macOS uses a per-domain resolver file:

```text
/etc/resolver/mpd.test
nameserver 10.163.0.3
```

Only `*.mpd.test` queries go to dnsmasq. Other domains continue using normal system DNS.

This is the standard macOS approach to split DNS — documented in `man 5 resolver`,
and the same mechanism Apple's own [`container`](https://github.com/apple/container)
tool uses (`container system dns create`) and that Laravel Valet has used for `.test`
domains for years. mpd-desktop is following the convention, not inventing one.

Typical mappings:
- `mpd.test` -> portal (`10.163.0.4`)
- service hostnames -> service IPs (`10.163.0.x`) by default
- `adminer.service.mpd.test` -> portal (`10.163.0.4`) for HTTPS reverse proxy
- `mail.<project>.mpd.test` -> runtime IP (per-project Mailpit UI via runtime's Caddy frontdoor, since mailpit is now a per-runtime sidecar)
- runtime/project hostnames -> runtime IPs (for example `10.163.0.102`)
- unknown `*.mpd.test` -> NXDOMAIN (no wildcard fallback)

## Request flow examples

```text
https://foo.mpd.test
  DNS: macOS resolver -> 10.163.0.3 (dnsmasq) -> runtime IP
  TCP: host -> runtime:443 via WireGuard tunnel

https://mpd.test
  DNS: -> 10.163.0.4 (portal)
  TCP: host -> portal:443 via WireGuard tunnel

ssh php.runtime.mpd.test
  DNS: -> runtime IP
  TCP: host -> runtime:22 via WireGuard tunnel
```

## Setup behavior (`mpd --setup`)

`mpd --setup` performs:

1. Adopt the running Podman machine (must be named `mpd-desktop` or `mpd-desktop-<suffix>`). `mpd` does not create Podman machines.
2. WireGuard key generation (`~/Developer/mpd/conf/wireguard/`)
3. WireGuard container creation with `-p 127.0.0.1:51820:51820/udp`
4. WireGuard tunnel config write/import for macOS app (`mpd-desktop.conf`)
5. resolver file setup for `mpd.test`

Once "On Demand" is enabled in WireGuard app, the tunnel reconnects automatically after reboot/sleep.

## Notes

- Only one host port mapping is required for networking bootstrap: `127.0.0.1:51820/udp`.
- Runtime pods do not need published host ports for normal development access.
- Security details: see `SECURITY.md`.
