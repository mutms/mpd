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

## What is being protected

**The workstation — not the VM.**

mpd exists to run other people's code: cloned Moodle branches, plugins
from the tracker, `composer install` post-scripts, npm lifecycle hooks,
and AI agents with a shell and passwordless sudo. That is the *job*, not
a risk to be engineered away. The VM and its containers are therefore
deliberately expendable: they are where random code from the internet is
allowed to run, and they are meant to absorb the damage when it
misbehaves.

Two consequences run through everything below:

- **Relaxations inside the VM are not oversights.** Passwordless sudo in
  containers, dev-grade DB credentials, no isolation between runtimes, a
  shared data volume — these buy ergonomics inside a boundary that is
  already assumed to be hostile.
- **The boundary that matters is VM → workstation.** That direction is
  one-way by construction: the CA private key never enters a VM (only
  the certificate does), SSH runs workstation → VM with no keys pointing
  back, and no container port is published to the workstation's own
  network.

### Where the isolation actually comes from

Ranked, weakest first:

1. **Podman containers — no security value.** Runtimes have
   passwordless sudo, share one data volume, sit on one network with no
   isolation between them, and are provisioned by scripts that run as
   root during bootstrap. Containers exist here for *reproducibility and
   convenience*, not confinement. Do not reason about them as a security
   boundary; nothing in mpd's design tries to make them one, and
   hardening them would not change the picture while sudo is
   passwordless by design.
2. **The hypervisor VM — the basic protection.** Parallels, Apple
   Virtualization, UTM, KVM: this is the first boundary that means
   anything. It is what stands between a malicious `postinstall` script
   and the workstation's filesystem, keychain, and SSH keys. Everything
   in "What is being protected" above rests on this layer, not on the
   container layer.
3. **A dedicated host — the real safety.** Running the VM on separate
   physical hardware (Proxmox) removes the shared-kernel and
   shared-hypervisor attack surface entirely. A hypervisor escape on the
   workstation reaches the workstation; on a dedicated box it reaches a
   machine that holds nothing of value.

### Prior art: GitHub's self-hosted runner guidance

The same reasoning, reached independently for the same problem —
executing untrusted code on infrastructure you own. GitHub's
[secure-use reference](https://docs.github.com/en/actions/reference/security/secure-use)
says self-hosted runners "do not have guarantees around running in
ephemeral clean virtual machines, and can be persistently compromised by
untrusted code in a workflow", and directs you to ask "what sensitive
information resides on the machine" (naming private SSH keys and API
tokens) and whether it "has network access to sensitive services",
concluding that "the amount of sensitive information in this environment
should be kept to a minimum".

Three things follow for mpd, because its runtimes are *pets* — long
lived, upgraded in place, never recreated (see `docs/ROADMAP.md`):

- **Assume persistent compromise.** A runtime that executes a malicious
  postinstall keeps it. Nothing resets it between projects, and mpd
  offers no scrubbing step. If you suspect one, delete the runtime.
- **Keep credentials out of the VM.** This is why the CA private key
  never leaves the workstation, and why it is worth resisting the
  temptation to park API tokens in `mpd-vm.env` for convenience.
- **`ssh -A` is the one live credential path in.** Agent forwarding
  gives anything running as the dev user in that container use of your
  key for the session — including a `git clone` you didn't start. It is
  listed under "Intentional compromises" below for exactly this reason.
  Forward it when you need it, not by default.

**So moving the VM further from the workstation is a security
improvement**, even though it exposes the VM more. Proxmox puts the
untrusted environment on a different physical machine: the workstation
gains isolation, the VM gains exposure (a LAN, not a NAT'd host-only
network). That is the right trade — it hardens the asset that matters at
the expense of the asset designed to be thrown away.

## Trust boundaries

```
Laptop (macOS)
  |
  | hypervisor network + host static route (10.163.<NNN>.0/24 → VM IP)
  |
VM host (Debian Trixie)
  |
  net.ipv4.ip_forward=1; mpd0 bridge (10.163.<NNN>.1/24)
  |   Two VM processes bind here, neither a container:
  |     dnsmasq :53  — resolver for .test, for the VM, the laptop and
  |                    every container (podman's own DNS is disabled)
  |     caddy  :443  — terminates TLS for the zone apex → mpd --web on
  |                    127.0.0.1, and for adminer → .6
  |
  mpd-internal network (10.163.<NNN>.0/24)
    +-- mpd-service-adminer    (10.163.<NNN>.6)
    +-- DB containers          (10.163.<NNN>.30–.99)
    +-- runtime pods           (10.163.<NNN>.100+, with per-runtime sidecars)

<NNN> is the VM's MPD_VM_ID. Each VM owns a distinct /24 and a distinct
DNS zone (<NNN>.mpd.test) — see docs/NETWORKING.md.
```

The container subnet is reachable from anything that can reach the VM
*and* has a route for `10.163.<NNN>.0/24` pointing at it. The boundary is
therefore whatever network the VM sits on:

- **Desktop hypervisor** (Parallels shared, libvirt default, Hyper-V
  Default Switch) — the VM is on a NAT'd network the developer's own
  machine owns. Nothing on the wider LAN can reach it.
- **LAN-hosted hypervisor** (Proxmox) — the VM is on the local
  network, so any machine on that LAN can install the same route and
  reach the containers. This is **accepted, and on balance preferred**:
  the untrusted environment moves off the workstation entirely. What is
  exposed is a machine whose whole purpose is to run untrusted code.

No container port is published beyond the VM in either case, and
authentication of individual endpoints is per-service — SSH keys for
runtimes, none for the read-only portal. So a LAN
neighbour who adds the route gets the portal and the DBs, not a shell.

**Who is trusted**: the developer. They have full access to
everything — SSH into runtimes, read/write all source code, admin
access to all databases, root via passwordless sudo inside containers.

**Who is not trusted**: anyone else — *and* everything the developer
runs inside a VM. Project code, dependencies, and agents are untrusted
guests that happen to be given a comfortable cage.

## Network access control

Nothing is published on the VM's own LAN address. caddy binds only the
podman bridge gateway `10.163.<NNN>.1`, and every container address is
inside `10.163.<NNN>.0/24` — so the whole environment, status page
included, is reachable only by a host that routes that subnet through
the VM.

The VM has `net.ipv4.ip_forward=1` (set by
`bootstrap/30-networking.sh`) — needed to route between the VM's
external NIC and `podman1`. It forwards for anyone who can reach the
VM and has the route; on a LAN-hosted VM that means the LAN. Don't put
an mpd VM on a network you don't trust.

## Portal security

The portal at `https://<NNN>.mpd.test/` is a read-only status page
rendered by `mpd --web` (`go/internal/web/`), a VM process listening on
`127.0.0.1:8099`. caddy terminates TLS in front of it. It displays
projects, runtimes, databases and services, and accepts no input.

It shows each project's **database connection details**, which are
guessable anyway — `db.CreateFor` derives user, password and database
name from the project name (see "Database credentials" below).

**Rules for portal code** (`go/internal/web/`):

- No command execution, no form handling, no request parameters that
  trigger actions
- No API endpoints, no webhook receivers, no proxy functionality
- Read state only (`state.Store`, `current.Observer`, `srv`) — never
  write
- Display information only — never mutate state

The package doc states these constraints, and they hold regardless of
authentication: a password would change who may look, not what the page
is allowed to do. There is no authentication today; anything with a
route to the container subnet — including project code running in a
runtime, which reaches the gateway — can read it.

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
| Per-project | `<project>.<NNN>.mpd.test` (+ `behat.<project>.<NNN>.mpd.test` for moodle) | `/srv/meta/<project>/cert.pem` (data volume) | Survives runtime recreation              |
| Per-runtime | `<n>.runtime.<NNN>.mpd.test`                                   | `/etc/ssl/mpd/` inside container             | Regenerated on runtime creation          |
| Services    | `<NNN>.mpd.test` (the VM's zone apex)                          | data volume `/srv/meta/`                     | Regenerated by `--vm-setup` when CA changes |

The CA private key **never enters any container**. Certificates are
signed inside the VM (in the `mpd` binary's host process) and written
into the data volume or copied into containers.

### CA trust inside containers

Each runtime gets the CA public cert (`rootCA.pem`) installed into its
system trust store during provisioning (`update-ca-certificates`).
This allows:

- `curl https://<project>.<NNN>.mpd.test/` from inside containers (no
  `--insecure` needed)
- Cross-runtime HTTPS requests
- Composer and npm HTTPS operations against `*.mpd.test` URLs

## Authentication

### SSH

Two SSH endpoints, both pubkey-only:

- **Runtime containers** (`<runtime>.runtime.<NNN>.mpd.test`) — full dev
  shell, passwordless sudo, the developer's UID. Each runtime creates
  a user account matching the developer's username and UID; the public
  key from `~/.ssh/authorized_keys` is propagated into the container.
  Root login disabled.
File transfer has no endpoint of its own. The data volume is mounted on
the VM at `/srv`, so `/srv/backups/` is reached over the VM's own sshd —
the connection the developer already has.

Reachable via the routed container subnet or via SSH ProxyJump
through the VM — no published ports.

SSH agent forwarding (`ssh -A`) is optional for runtimes that need
host-agent-backed git/auth inside the container. It passes the
developer's key into the container for the session — the private key
never touches the container filesystem.

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
for `10.163.<NNN>.0/24` is installed. The VM host can reach containers
natively via `podman1`.

## What mpd does NOT protect against

- **Malicious code in projects, *within the VM***: a repo with a
  malicious `composer install` post-script or npm lifecycle hook runs
  with full access to `/srv/` and the network, and can reach every
  other container. mpd adds no sandbox *inside* the VM — the VM is the
  sandbox. Compared with running `composer install` directly on your
  workstation this is a large improvement; compared with a hardened
  per-project jail it is no protection at all. Assume anything that
  executes in a runtime owns the whole VM.
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
| PostgreSQL `synchronous_commit=off`                           | Trades a little crash durability for speed: an unclean shutdown loses at most the last fraction of a second of commits. Bounded, and no corruption. `full_page_writes` is deliberately left ON — turning it off risks a torn page postgres cannot repair, and unclean shutdowns are routine here (an OOM'd VM never runs `mpd --vm-stop`, so the graceful-shutdown hooks never fire). Losing seconds of work is an acceptable dev tradeoff; losing the database is not. |
| Behat uses a separate subdomain                              | Behat runs on `behat.<project>.<NNN>.mpd.test` (HTTPS, same cert). The mpd CA is installed in the Selenium container so Chromium trusts `*.mpd.test` certificates.                                                                                 |
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
