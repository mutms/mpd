# mpd Security Model

mpd is a local development environment for a single developer, on
machines that developer controls. That audience is the premise of
every tradeoff below: mpd assumes an operator who understands the
network model and accepts it deliberately. It is **not** a demo or
onboarding platform for non-technical users, and nothing here should
be relaxed or hardened on their behalf.

This document describes the trust
boundaries, threat model, and security properties of the in-VM `mpd`
binary; for host-side concerns (CA trust import, route + DNS) see
`mpd-virt`'s own documentation.

## Non-Root Execution Policy

`mpd` is a non-root CLI. Run it as a regular user only.

- Do not run `mpd` via `sudo`.
- Do not launch `mpd` as root.
- `sudo` is used only for specific host integration commands that
  `mpd-virt` asks you to run explicitly (for example CA trust).

Rationale: prevents UID/ownership drift and reduces risk of
permission-related breakage or accidental data loss.

## Trust boundaries

```
Laptop (macOS)
  |
  | hypervisor network + host static route (10.163.0.0/24 → VM IP)
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

The container subnet is reachable from anything that can reach the VM
*and* has a route for `10.163.0.0/24` pointing at it. The boundary is
therefore whatever network the VM sits on:

- **Desktop hypervisor** (Parallels shared, libvirt default, Hyper-V
  Default Switch) — the VM is on a NAT'd network the developer's own
  machine owns. Nothing on the wider LAN can reach it.
- **LAN-hosted hypervisor** (Proxmox) — the VM is on the local
  network, so any machine on that LAN can install the same route and
  reach the containers. This is **accepted**: mpd treats a trusted
  home/office LAN as inside the boundary.

No container port is published beyond the VM in either case, and
authentication of individual endpoints is per-service — SSH keys for
runtimes and fileaccess, none for the read-only portal. So a LAN
neighbour who adds the route gets the portal and the DBs, not a shell.

**Who is trusted**: the developer. They have full access to
everything — SSH into runtimes, read/write all source code, admin
access to all databases, root via passwordless sudo inside containers.

**Who is not trusted**: anyone else.

## Network access control

Only the **portal's `:443`** and (optionally) **dnsmasq's `:53`** are
published on the VM via Podman port-publish. Everything else is
reachable only by a host that routes `10.163.0.0/24` through the VM.

The VM has `net.ipv4.ip_forward=1` (set by
`bootstrap/30-networking.sh`) — needed to route between the VM's
external NIC and `podman1`. It forwards for anyone who can reach the
VM and has the route; on a LAN-hosted VM that means the LAN. Don't put
an mpd VM on a network you don't trust.

## Portal security

The portal at `https://mpd.test/` is a read-only status page served by
`mpd-service-portal`. It displays project names, runtime status, URLs,
and setup instructions. It accepts no user input and executes no
commands.

**Rules for portal code** (`assets/services/portal/*.php`):

- No `exec()`, `system()`, `shell_exec()`, `passthru()`, `popen()`, or
  backtick operators
- No form handling, no `$_POST`, no `$_GET` processing that triggers
  actions
- No API endpoints, no webhook receivers, no proxy functionality
- Read from filesystem only (`/srv/meta/`, `/mpd-state/`) — never
  write
- Display information only — never mutate state

These constraints are documented in the PHP files themselves.

## TLS and the certificate authority

The CA is generated on the host by `mpd-virt` (separate orchestrator,
separate repo). The CA signs all TLS certificates used within the
environment. The in-VM `mpd` binary receives the CA keypair from the
host during provisioning and uses it to sign per-project, per-runtime,
and per-service certs.

### CA properties

| Property                | Value                                                           |
|-------------------------|-----------------------------------------------------------------|
| Host-side location      | `~/.mpd-virt/conf/caroot/rootCA.pem` + `rootCA-key.pem` (on macOS)   |
| In-VM working location  | data volume `/srv/meta/ca/`                                     |
| CA validity             | 10 years                                                        |
| Leaf cert validity      | 397 days (macOS requires < 398 for trust)                       |
| Name constraints        | `mpd.test` + `.mpd.test` only                                   |
| Key permissions         | `rootCA-key.pem` mode `0600`                                    |
| macOS trust             | System Keychain via `security add-trusted-cert -d -r trustRoot` |

**Name constraints** limit the CA to signing certificates for
`*.mpd.test` domains only. Even if the CA key is compromised, it
cannot sign certificates for real domains (e.g. `google.com`).
Browsers enforce name constraints.

**Host-only trust rule.** CAs flow host → VM only. The macOS keychain
only ever trusts certificates the host generated itself. `mpd-virt`
generates the CA on the host *before* creating the VM and pushes it
into the VM at provisioning time.

### Certificate types

| Certificate | SAN                                                            | Stored at                                    | Lifetime                                 |
|-------------|----------------------------------------------------------------|----------------------------------------------|------------------------------------------|
| Per-project | `<project>.mpd.test` (+ `behat.<project>.mpd.test` for moodle) | `/srv/meta/<project>/cert.pem` (data volume) | Survives runtime recreation              |
| Per-runtime | `<n>.runtime.mpd.test`                                         | `/etc/ssl/mpd/` inside container             | Regenerated on runtime creation          |
| Services    | `mpd.test`                                                     | data volume `/srv/meta/`                     | Regenerated by `--setup` when CA changes |

The CA private key **never enters any container**. Certificates are
signed inside the VM (in the `mpd` binary's host process) and written
into the data volume or copied into containers.

### CA trust inside containers

Each runtime gets the CA public cert (`rootCA.pem`) installed into its
system trust store during provisioning (`update-ca-certificates`).
This allows:

- `curl https://<project>.mpd.test/` from inside containers (no
  `--insecure` needed)
- Cross-runtime HTTPS requests
- Composer and npm HTTPS operations against `*.mpd.test` URLs

## Authentication

### SSH

Two SSH endpoints, both pubkey-only:

- **Runtime containers** (`<runtime>.runtime.mpd.test`) — full dev
  shell, passwordless sudo, the developer's UID. Each runtime creates
  a user account matching the developer's username and UID; the public
  key from `~/.ssh/authorized_keys` is propagated into the container.
  Root login disabled.
- **fileaccess service** (`fileaccess.service.mpd.test`) — file-transfer
  endpoint only. Same user/UID as runtimes, **no sudo**, no
  agent/TCP forwarding, no port mapping. Lands ssh sessions in
  `/srv/backups/` (a data-volume subdirectory, the single transit
  point for project backups).

Reachable via the routed container subnet or via SSH ProxyJump
through the VM — no published ports on either endpoint.

SSH agent forwarding (`ssh -A`) is optional for runtimes that need
host-agent-backed git/auth inside the container. It passes the
developer's key into the container for the session — the private key
never touches the container filesystem. fileaccess does not need agent
forwarding (it's not a shell environment).

**Lost the laptop's private key?** The simplest recovery is to
re-clone the template via `mpd-virt clone` and side-by-side it with
the old VM until you've migrated anything you care about. If you want
to rescue the existing VM instead, boot it via the hypervisor's
console into single-user mode and replace
`~/.ssh/authorized_keys` directly.

### Database credentials

Dev-only credentials — not designed for security:

| Engine     | Per-project                | Superuser               |
|------------|----------------------------|-------------------------|
| PostgreSQL | user/pass/db = `<project>` | `postgres` / `postgres` |
| MariaDB    | user/pass/db = `<project>` | `root` / `root`         |
| MySQL      | user/pass/db = `<project>` | `root` / `root`         |

Databases are reachable only from the routed container subnet (or from
inside containers). No DB ports are exposed on `0.0.0.0` of the LAN.

## Key and credential storage

| Secret                  | Location                                       | Permissions       |
|-------------------------|------------------------------------------------|-------------------|
| CA private key          | `~/.mpd-virt/conf/caroot/rootCA-key.pem` (host)     | `0600`            |
| Per-project TLS keys    | `/srv/meta/<project>/key.pem`                  | Inside data volume|
| SSH authorized keys     | `/home/<user>/.ssh/authorized_keys`            | Inside containers |

The host-side `mpd-virt uninstall` removes the VM and host-side
networking; it offers to remove the CA from the macOS Keychain.
The host's `~/.mpd-virt/conf/` is preserved by design (so a re-setup
reuses the same CA). In-VM state lives under `/var/lib/mpd/`
on the VM filesystem and is wiped when the VM itself is deleted.

## Container isolation

All containers run under rootful Podman inside the VM. They share a
single Podman network (`mpd-internal`) and a single data volume
(`mpd-data-volume` mounted at `/srv/`).

**Containers are not isolated from each other.** Any container can
reach any other container on `mpd-internal`. All runtimes mount the
same data volume — a process in the `php` runtime can read files
belonging to `node` runtime projects. This is intentional for a
single-developer environment.

Containers are unreachable from the laptop until the host static route
for `10.163.0.0/24` is installed. The VM host can reach containers
natively via `podman1`.

## What mpd does NOT protect against

- **Malicious code in projects**: if you clone a repo with a
  malicious `composer install` post-script or npm lifecycle hook, it
  runs with full access to `/srv/` and the network. This is the same
  risk as running `composer install` on your Mac — mpd adds no
  sandbox.
- **Compromised runtime containers**: containers have passwordless
  sudo and network access. A compromised container can reach all other
  containers and all data in the volume.
- **Physical access to the host**: anyone with access to
  `~/.mpd-virt/conf/` can read the CA key.

## Intentional compromises

These are deliberate tradeoffs — security relaxed in exchange for dev
ergonomics. All are safe in a single-developer local environment but
would be unacceptable in production.

| Compromise                                                   | Rationale                                                                                                                                                                                                                                    |
|--------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Passwordless `sudo` inside containers                        | Dev needs root for package installs, service restarts, config changes. No security boundary between the dev user and root inside a container.                                                                                                |
| Apache `Require all granted` + `AllowOverride All`           | Every project is fully accessible — no auth, no IP restrictions. Access control is at the network level (the container subnet is routed only from the developer's own machine), not the web server level.                                                                                        |
| PostgreSQL `synchronous_commit=off` + `full_page_writes=off` | Trades crash durability for speed. A power failure or VM crash can corrupt the DB. Acceptable in this dev-only model because data can be recreated.                                                                                          |
| Behat uses a separate subdomain                              | Behat runs on `behat.<project>.mpd.test` (HTTPS, same cert). The mpd CA is installed in the Selenium container so Chromium trusts `*.mpd.test` certificates.                                                                                 |
| Shared data volume across all containers                     | All runtimes, DB containers, and services mount `mpd-data-volume` at `/srv/`. A process in one container can read/write data belonging to another. This is the single-volume design — simplicity over isolation.                             |
| SSH agent forwarding                                         | `ssh -A` passes the developer's key into the container. Any process running as the dev user inside the container could use the forwarded key for the duration of the session. Standard SSH risk — same as forwarding into any remote server. |
| Dev database credentials                                     | User, password, and database name all equal the project name. Superuser passwords are `postgres`/`root`. See "Database credentials" above.                                                                                                   |

## Design decisions

**Why dev credentials instead of random passwords?** mpd is a local
dev tool. Strong DB passwords add friction (copy-pasting into
PhpStorm, Adminer, config files) with no security benefit — the DB is
only reachable from the developer's own machine. The project name as user/pass/db
makes setup trivial.

**Why a private CA instead of self-signed certs?** One CA trust
operation during setup, then every project and runtime gets a trusted
certificate automatically. No browser warnings, no `--insecure` flags,
no per-cert trust clicks. Name constraints limit the blast radius.

**Why a routed subnet instead of port forwarding?** Direct IP access
to every container: SSH on standard port 22, HTTPS on standard port
443, multiple runtimes with the same ports, no port conflict
management. One persistent static route plus a scoped resolver entry
per VM, installed once by `mpd-virt` — nothing to toggle daily, and it
coexists with a corporate VPN instead of fighting it for a tunnel
slot.

**Why not WireGuard any more?** mpd previously tunnelled host → VM
because the container network of the day couldn't be routed into from
the host at all — the tunnel was the only way to get direct container
IPs. Once mpd moved to its own VM under a real hypervisor, a plain
static route does the same job. The tunnel then only cost: macOS
allows one active tunnel at a time, so it could never reach two mpd
VMs at once and it competed with the developer's work VPN for that
single slot. Removing it trades an authenticated transport for a
network-level boundary — see "Trust boundaries" above for what that
means on a LAN-hosted VM.
