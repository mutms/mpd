# mpd Security Model

mpd is a local development environment. It is designed for a single developer on a personal machine. This document describes the trust boundaries, threat model, and security properties.

## Non-Root Execution Policy

`mpd` is a non-root CLI. Run it as a regular user only.

- Do not run `mpd` via `sudo`.
- Do not launch `mpd` as root.
- `sudo` is used only for specific host integration commands that `mpd` asks you to run explicitly (for example CA trust and DNS resolver setup).

Rationale: prevents UID/ownership drift and reduces risk of permission-related breakage or accidental data loss.

## Trust boundaries

mpd-desktop and mpd-machine share the container topology but differ in how
the developer's host reaches it.

### mpd-desktop (macOS host + Podman machine)

```
Internet / office LAN
  |
  | (normally blocked — no listening ports on Mac)
  |
Mac (developer's machine)
  |
  | WireGuard tunnel (encrypted, authenticated)
  | 127.0.0.1:51820/udp (loopback only — not LAN-reachable)
  |
Podman machine VM
  |
  mpd-internal network (10.163.0.0/24)
    +-- mpd-service-wireguard  (10.163.0.2)
    +-- mpd-service-dnsmasq    (10.163.0.3)
    +-- mpd-service-portal     (10.163.0.4)
    +-- mpd-service-fileaccess (10.163.0.5)
    +-- mpd-service-adminer    (10.163.0.6)
    +-- DB containers          (10.163.0.30–.99)
    +-- runtime pods           (10.163.0.100+, with per-runtime sidecars)
```

### mpd-machine (Linux VM, laptop is external)

```
Laptop  (192.168.x.x on home LAN, or UTM bridge 192.168.64.x)
  |
  | Static route: 10.163.0.0/24 via <vm-ip>
  | (No tunnel — relies on LAN trust + VM kernel routing)
  |
VM host (Debian Trixie)
  |
  net.ipv4.ip_forward=1; podman1 bridge (10.163.0.1/24)
  |
  mpd-internal network (10.163.0.0/24)
    +-- mpd-service-dnsmasq    (10.163.0.3)
    +-- mpd-service-portal     (10.163.0.4)
    +-- mpd-service-fileaccess (10.163.0.5)
    +-- mpd-service-adminer    (10.163.0.6)
    +-- DB containers          (10.163.0.30–.99)
    +-- runtime pods           (10.163.0.100+, with per-runtime sidecars)
```

WireGuard is not used on Machine. The laptop's reachability of the container
subnet is gated by (a) being on the same LAN as the VM and (b) knowing both
the route to add and the VM's IP.

**Who is trusted**: the developer. They have full access to everything — SSH into runtimes, read/write all source code, admin access to all databases, root via passwordless sudo inside containers.

**Who is not trusted**: anyone else.

## Network access control

### mpd-desktop (macOS, primary platform)

The WireGuard bootstrap port binds to `127.0.0.1:51820/udp` on macOS — loopback only, not LAN-reachable. Container IPs are routed through the WireGuard tunnel, which requires the developer's private key to establish. **No ports are exposed on `0.0.0.0`.**

### mpd-machine (Linux VM)

The VM exposes only the **portal's `:443`** and (optionally) **dnsmasq's `:53`** via Podman port-publish. With UTM's QEMU Shared Network mode, those ports are reachable from the macOS host only (the VM lives on a host-internal subnet — `192.168.64.x` typically — with no path from the rest of the LAN).

Threats to consider:

- **UTM Bridged Network mode** would put the VM on the home LAN directly (e.g. `192.168.1.x`). At that point any device on the LAN could reach the VM and, with knowledge of the route, the container subnet. Use Bridged mode only on trusted networks.
- **The static route on the laptop is local-only** — adding `10.163.0.0/24 via <vm-ip>` only affects the laptop's routing table. Other LAN devices cannot reach the VM in Shared Network mode regardless.
- **The VM has `net.ipv4.ip_forward=1`** — this is needed to route between `wg0`/`podman1`/`eth0`. By itself it does not expose anything; it only forwards packets that already arrive at the VM. With Shared Network mode, those packets only originate from the macOS host.

mpd does not encrypt traffic between laptop and VM in machine mode. The trust model relies on:

1. The VM being on a host-internal subnet (Shared Network mode), or
2. The home LAN being trusted (Bridged Network mode).

If neither holds, do not use mpd-machine — use mpd-desktop (which retains the WireGuard tunnel).

## Portal security

The portal at `https://mpd.test/` is a read-only status page served by `mpd-service-portal`. It displays project names, runtime status, URLs, and setup instructions. It accepts no user input and executes no commands.

**Rules for portal code** (`assets/services/portal/*.php`):

- No `exec()`, `system()`, `shell_exec()`, `passthru()`, `popen()`, or backtick operators
- No form handling, no `$_POST`, no `$_GET` processing that triggers actions
- No API endpoints, no webhook receivers, no proxy functionality
- Read from filesystem only (`/srv/meta/`, `/mpd-state/`) — never write
- Display information only — never mutate state

These constraints are documented in the PHP files themselves.

## TLS and the certificate authority

mpd generates a private CA at `mpd --setup` time. The CA signs all TLS certificates used within the environment.

### CA properties

| Property | Value |
|---|---|
| Location | `~/Developer/mpd/conf/caroot/rootCA.pem` + `rootCA-key.pem` |
| CA validity | 10 years |
| Leaf cert validity | 397 days (macOS requires < 398 for trust) |
| Name constraints | `mpd.test` + `.mpd.test` only |
| Key permissions | `rootCA-key.pem` mode `0600` |
| macOS trust | Added to login Keychain via `security add-trusted-cert` |

**Name constraints** limit the CA to signing certificates for `*.mpd.test` domains only. Even if the CA key is compromised, it cannot sign certificates for real domains (e.g. `google.com`). Browsers enforce name constraints.

### Certificate types

| Certificate | SAN | Stored at | Lifetime |
|---|---|---|---|
| Per-project | `<project>.mpd.test` (+ `behat.<project>.mpd.test` for moodle) | `/srv/meta/<project>/cert.pem` (data volume) | Survives runtime recreation |
| Per-runtime | `<n>.runtime.mpd.test` | `/etc/ssl/mpd/` inside container | Regenerated on runtime creation |
| Services | `mpd.test` | `~/Developer/mpd/conf/service/` | Regenerated by `--setup` when CA changes |

The CA private key **never enters any container**. Certificates are signed on the Mac and written into the data volume or copied into containers.

### CA trust inside containers

Each runtime gets the CA public cert (`rootCA.pem`) installed into its system trust store during provisioning (`update-ca-certificates`). This allows:

- `curl https://<project>.mpd.test/` from inside containers (no `--insecure` needed)
- Cross-runtime HTTPS requests
- Composer and npm HTTPS operations against `*.mpd.test` URLs

## Authentication

### SSH

Two SSH endpoints, both pubkey-only:

- **Runtime containers** (`<runtime>.runtime.mpd.test`) — full dev shell, passwordless sudo, the developer's UID. Each runtime creates a user account matching the developer's username and UID; the public key from `~/.ssh/authorized_keys` is propagated into the container. Root login disabled.
- **fileaccess service** (`fileaccess.service.mpd.test`) — file-transfer endpoint only. Same user/UID as runtimes, **no sudo**, no agent/TCP forwarding, no port mapping. Lands ssh sessions in `/srv/backups/` (a data-volume subdirectory, the single transit point for project backups). Authorized keys are bind-mounted read-only from the VM user's `~/.ssh/authorized_keys` (cloud-init populated it from the laptop's pubkey).

Reachable only via the static route to the VM's container subnet — no public exposure on either endpoint.

SSH agent forwarding (`ssh -A`) is optional for runtimes that need host-agent-backed git/auth inside the container. It passes the developer's key into the container for the session — the private key never touches the container filesystem. fileaccess does not need agent forwarding (it's not a shell environment).

**Lost the laptop's private key?** Recovery via UTM single-user mode is documented in [`mpd-machine/platforms/macos-utm/README.md`](../../mpd-machine/platforms/macos-utm/README.md#recovery-lost-ssh-key) — the gotcha is that the VM has no graphical display, so you first need to point UTM's serial console at its built-in terminal before GRUB output is visible.

### WireGuard (mpd-desktop only)

WireGuard uses Curve25519 keypairs for authentication. Only the holder of the Mac's WireGuard private key can establish the tunnel. Keys are generated once during `mpd --setup` and stored at `~/Developer/mpd/conf/wireguard/` (mode `0700`).

The tunnel config (`mpd-desktop.conf`) contains the Mac private key — treat it like an SSH private key.

Operational rule: private keys must not be printed to terminal output by `mpd`. `~/Developer/mpd/conf/` is canonical secret storage; transfer of public artifacts (CA cert, setup recipe via `mpd --setup-info`) goes through `scp/ssh`.

### mpd-machine: no WireGuard, route + LAN trust instead

mpd-machine does not use WireGuard. Authentication of laptop ↔ container traffic relies on (a) the VM living on a host-internal subnet (UTM Shared Network mode), or (b) the home LAN being trusted (Bridged Network mode). See "Network access control" above.

### Database credentials

Dev-only credentials — not designed for security:

| Engine | Per-project | Superuser |
|---|---|---|
| PostgreSQL | user/pass/db = `<project>` | `postgres` / `postgres` |
| MariaDB | user/pass/db = `<project>` | `root` / `root` |
| MySQL | user/pass/db = `<project>` | `root` / `root` |

On mpd-desktop, databases are reachable only through the WireGuard tunnel (or from inside containers). On mpd-machine, databases are reachable from the laptop via the static route. In either case, no DB ports are exposed on `0.0.0.0` of the LAN.

## Key and credential storage

| Secret | Location | Permissions | Used by |
|---|---|---|---|
| CA private key | `~/Developer/mpd/conf/caroot/rootCA-key.pem` | `0600` | both modes |
| WireGuard keys | `~/Developer/mpd/conf/wireguard/` | `0700` directory | desktop only |
| WireGuard tunnel config | `~/Developer/mpd/conf/wireguard/mpd-desktop.conf` | Contains Mac private key | desktop only |
| Per-project TLS keys | `/srv/meta/<project>/key.pem` | Inside data volume | both modes |
| SSH authorized keys | `/home/<user>/.ssh/authorized_keys` | Inside containers | both modes |

`mpd --uninstall` removes `~/.mpd/` state/cache and offers to remove the CA from the macOS Keychain. `~/Developer/mpd/conf/` is preserved by design. The data volume (containing per-project TLS keys) is preserved unless explicitly deleted.

## Container isolation

All containers run inside a Podman VM (macOS) or under rootful Podman (Linux). They share a single Podman network (`mpd-internal`) and a single data volume (`mpd-data-volume` mounted at `/srv/`).

**Containers are not isolated from each other.** Any container can reach any other container on `mpd-internal`. All runtimes mount the same data volume — a process in the `php` runtime can read files belonging to `node` runtime projects. This is intentional for a single-developer environment.

On **mpd-desktop**, containers are isolated from the Mac — the WireGuard tunnel is the only path in. Without the tunnel, container IPs are unreachable (gvproxy blocks direct access).

On **mpd-machine**, containers are isolated from the laptop until the static route is added. Without the route, container IPs are unreachable from the laptop. The VM host can reach containers natively via `podman1`.

## What mpd does NOT protect against

- **Malicious code in projects**: if you clone a repo with a malicious `composer install` post-script or npm lifecycle hook, it runs with full access to `/srv/` and the network. This is the same risk as running `composer install` on your Mac — mpd adds no sandbox.
- **Compromised runtime containers**: containers have passwordless sudo and network access. A compromised container can reach all other containers and all data in the volume.
- **Physical access to the host**: anyone with access to `~/Developer/mpd/conf/` can read the CA key (and, on mpd-desktop, the WireGuard keys and tunnel config).
- **Shared Podman machines**: mpd assumes one developer per Podman machine. Multiple users sharing a machine is not supported and would have no isolation.

## Intentional compromises

These are deliberate tradeoffs — security relaxed in exchange for dev ergonomics. All are safe in a single-developer local environment but would be unacceptable in production.

| Compromise | Rationale |
|---|---|
| Passwordless `sudo` inside containers | Dev needs root for package installs, service restarts, config changes. No security boundary between the dev user and root inside a container. |
| Apache `Require all granted` + `AllowOverride All` | Every project is fully accessible — no auth, no IP restrictions. Access control is at the network level (WireGuard tunnel on mpd-desktop, static route + LAN trust on mpd-machine), not the web server level. |
| PostgreSQL `synchronous_commit=off` + `full_page_writes=off` | Trades crash durability for speed. A power failure or VM crash can corrupt the DB. Acceptable in this dev-only model because data can be recreated. |
| Behat uses a separate subdomain | Behat runs on `behat.<project>.mpd.test` (HTTPS, same cert). The mpd CA is installed in the Selenium container so Chromium trusts `*.mpd.test` certificates. |
| Shared data volume across all containers | All runtimes, DB containers, and services mount `mpd-data-volume` at `/srv/`. A process in one container can read/write data belonging to another. This is the single-volume design — simplicity over isolation. |
| SSH agent forwarding | `ssh -A` passes the developer's key into the container. Any process running as the dev user inside the container could use the forwarded key for the duration of the session. Standard SSH risk — same as forwarding into any remote server. |
| Dev database credentials | User, password, and database name all equal the project name. Superuser passwords are `postgres`/`root`. See "Database credentials" above. |

## Design decisions

**Why dev credentials instead of random passwords?** mpd is a local dev tool. Strong DB passwords add friction (copy-pasting into PhpStorm, Adminer, config files) with no security benefit — the DB is only reachable through the tunnel. The project name as user/pass/db makes setup trivial.

**Why a private CA instead of self-signed certs?** One CA trust operation during setup, then every project and runtime gets a trusted certificate automatically. No browser warnings, no `--insecure` flags, no per-cert trust clicks. Name constraints limit the blast radius.

**Why WireGuard on Desktop?** Direct IP access to every container. SSH on standard port 22. HTTPS on standard port 443. Multiple runtimes with the same ports. No port conflict management. The macOS host has no other route into the Podman machine VM, so a WG tunnel is the natural transport.

**Why no WireGuard on Machine?** On mpd-machine the laptop is *outside* the UTM VM but reachable via plain L3 routing (LAN), so a tunnel is unnecessary work. Removing WG drops kernel-module dependencies and key rotation. The trust model relies on Shared Network mode keeping the VM on a host-internal subnet.
