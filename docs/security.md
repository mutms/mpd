# mpd Security Model

mpd is a local development environment for one developer, on machines
that developer controls. Every tradeoff below assumes an operator who
understands the network model and accepts it. mpd is **not** a demo or
onboarding platform for non-technical users. Do not relax or harden
anything here on their behalf.

This document describes the trust boundaries, threat model and security
properties of the in-VM `mpd` binary. Host-side topics (CA trust import,
route and DNS) are in `mpd-virt`'s own documentation.

## Non-Root Execution Policy

`mpd` is a non-root CLI. Run it as a regular user only.

- Do not run `mpd` via `sudo`.
- Do not launch `mpd` as root.
- `sudo` is used only for specific host integration commands that
  `mpd-virt` asks you to run explicitly (for example CA trust).

Rationale: prevents UID/ownership drift and reduces risk of
permission-related breakage or accidental data loss.

The exception is mpd-proxy on the host: `sudo mpd-proxy up` needs root
to create the tunnel device, the route and the resolver hook, then drops
to the invoking user. mpd-proxy is optional — a SOCKS5 proxy over SSH
or RDP to the VM desktop works without it.

## What is being protected

**The workstation — not the VM.**

mpd exists to run other people's code: cloned Moodle branches, plugins
from the tracker, `composer install` post-scripts, npm lifecycle hooks,
and AI agents with a shell and passwordless sudo. That is the job. The
VM and its containers are expendable: they are where untrusted code
runs, and they are meant to take the damage when it misbehaves.

Two consequences follow:

- **Relaxed settings inside the VM are intentional.** Passwordless sudo
  in the runtime, dev-grade DB credentials, no isolation between
  containers, one shared data volume. They make work easier inside a
  boundary that is already assumed to be hostile.
- **The boundary that matters is VM → workstation.** It is one-way: the
  root CA private key never enters a VM (a VM gets its own intermediate,
  limited to its own DNS zone), SSH goes workstation → VM with no keys
  pointing back, and no container port is published on the
  workstation's network.

### Where the isolation actually comes from

Ranked, weakest first:

1. **Podman containers — no security value.** The runtime has
   passwordless sudo. Containers share one data volume and one network
   with no isolation between them, and bootstrap scripts provision them
   as root. Containers are here for reproducibility and convenience, not
   confinement. Do not treat them as a security boundary. Hardening them
   would change nothing while sudo is passwordless by design.
2. **The hypervisor VM — the basic protection.** Parallels, Apple
   Virtualization, UTM, KVM. This is the first boundary that matters. It
   is what separates a malicious `postinstall` script from the
   workstation's filesystem, keychain and SSH keys. Everything in "What
   is being protected" rests on this layer.
3. **A dedicated host — the real safety.** Running the VM on separate
   hardware (Proxmox) removes the shared-kernel and shared-hypervisor
   attack surface. A hypervisor escape on the workstation reaches the
   workstation. On a dedicated box it reaches a machine that holds
   nothing of value.

### Prior art: GitHub's self-hosted runner guidance

GitHub reached the same conclusions for the same problem: running
untrusted code on infrastructure you own. Its
[secure-use reference](https://docs.github.com/en/actions/reference/security/secure-use)
says self-hosted runners "do not have guarantees around running in
ephemeral clean virtual machines, and can be persistently compromised by
untrusted code in a workflow". It tells you to ask "what sensitive
information resides on the machine" (private SSH keys, API tokens) and
whether it "has network access to sensitive services", and concludes
that "the amount of sensitive information in this environment should be
kept to a minimum".

Three things follow for mpd, because its runtime is long-lived and
nothing resets it between projects:

- **Assume persistent compromise.** A runtime that ran a malicious
  postinstall keeps it, and so does the VM around it. If you suspect
  one, throw the whole VM away and create a new one. Do not back
  anything up from it unless it is truly irreplaceable — a backup
  carries the compromise with it.
- **Keep credentials out of the VM.** This is why the root CA private
  key stays on the workstation and the VM gets only a zone-limited
  intermediate. It is also why you should not put API tokens in
  `runtime.env` for convenience.
- **`ssh -A` is the one live credential path in.** Agent forwarding lets
  anything running as the dev user in that container use your key for
  the session — including a `git clone` you did not start. Do not
  forward it into a session where an AI agent works. Let the agent
  edit and test inside the VM without your key, and push from the host
  (PhpStorm or a host terminal, with your key) instead. See
  "Intentional compromises".

**Moving the VM further from the workstation improves security**, even
though it exposes the VM more. Proxmox puts the untrusted environment on
a different physical machine: the workstation gains isolation, the VM
gains exposure (a LAN instead of a NAT'd host-only network). That is the
right trade. It hardens the asset that matters at the expense of the
asset that is designed to be thrown away.

## Trust boundaries

```
Laptop
  │  always: SSH (tcp/22, key only) → management, ProxyJump into the runtime
  │    • optional SOCKS5 proxy (ssh -D) uses this SSH connection: it opens
  │      127.0.0.1:1080 on the laptop, nothing new on the VM
  │  optional: WireGuard overlay (udp/51820, mpd-proxy) → the whole container /24
  │  optional: RDP (tcp/3389, after rdp-start, password) → the VM's GNOME desktop
  │
VM host (Debian Trixie)     exposes :22 (sshd) + :51820 (wg, silent until a
  │                         peer is registered) on its LAN IP; :3389 only while RDP is on
  │
  │  mpdbr0 bridge  10.163.<NNN>.1/24 — internal; nothing binds the LAN IP
  │    dnsmasq :53  — resolver for .test (bound to .1 only)
  │    caddy  :443  — TLS for the zone apex only → mpd --web (127.0.0.1)
  │
  mpd-internal network (10.163.<NNN>.0/24) — sealed from the LAN (nft
    │                         firewall; only the bridge and wg0 route in)
    +-- mpd-<NNN>-runtime        (10.163.<NNN>.2 — in-runtime caddy
    │                             terminates project HTTPS)
    +-- DB containers            (10.163.<NNN>.10–.99)
    +-- extra service containers (10.163.<NNN>.100–.199 — optional, plain
                                  HTTP: mailpit, adminer, seleniumv1)

<NNN> is the VM's id, from its hostname mpd-<NNN>. Each VM owns a
distinct /24 and a distinct
DNS zone (<NNN>.mpd.test) — see docs/networking.md.
```

**The container subnet is not reachable from the LAN or from the public
side of the VM.** The developer's laptop reaches the whole /24 through
sshd (SOCKS or ProxyJump), or over the optional WireGuard overlay
(`mpd-virt` sets the peer's AllowedIPs to the /24). An in-VM nftables
firewall (`mpd-firewall.service`, installed by `mpd --vm-setup`) drops
any new forwarded connection into `10.163.<NNN>.0/24` from any interface
other than the bridge and `wg0`. Container→internet (masquerade) is not
affected.

So the VM exposes **two ports, both cryptographically authenticated**:

- **`tcp/22` — SSH.** Pubkey-only, root login disabled. Always open.
  The SOCKS5 proxy and ProxyJump are SSH connections to this port.
- **`udp/51820` — WireGuard.** Used only with mpd-proxy. The laptop's
  mpd-proxy is the only authorised peer; wg silently drops everything
  else, so without mpd-proxy the port answers nobody.

Everything else — portal, project HTTPS, databases, extra services, the
runtime — sits behind those two ports. Nothing is published on the VM's
LAN address.

**The optional third port: `tcp/3389` — RDP.** `rdp-start` installs
and starts xrdp so the VM's GNOME desktop can be reached from a device
that cannot hold an SSH tunnel or the WireGuard overlay, such as a
tablet. It is off after every bootstrap, it is never enabled for you,
and `rdp-stop` removes it again. It is the one port protected by the
dev user's **password** (xrdp authenticates through PAM), not a key.
`rdp-start` turns SSH password authentication off (once a key is
installed), so the password works for RDP only. Expose the port on a
hypervisor's host-only network, or on a private network behind a
bastion or a zero-trust tunnel. Not on the open internet. See
"Intentional compromises".

**Topology does not matter.** Because only
ssh and wg (and RDP, if you turned it on) are reachable over the
network, a VM is safe to run anywhere the laptop can reach it by IP:

- **Desktop hypervisor** (Parallels, UTM, Apple container, libvirt) — a
  NAT'd host-only network the laptop owns.
- **LAN- or datacentre-hosted** (Proxmox, a cloud VM) — a routable IP,
  even a public one. A LAN neighbour or an internet scanner sees only wg
  (silent) and ssh (pubkey-only). The container subnet is invisible to
  them. This is **preferred**: the untrusted environment leaves the
  workstation entirely, and the small exposed surface makes that safe.

**Who is trusted**: the developer. They have full access to everything:
SSH into the runtime, read/write on all source code, admin access to all
databases, root via passwordless sudo inside containers.

**Who is not trusted**: anyone else, *and* everything the developer runs
inside a VM. Project code, dependencies and agents are untrusted guests
in a convenient environment.

## Network access control

Nothing is published on the VM's own LAN address. caddy and dnsmasq bind
only the podman bridge gateway `10.163.<NNN>.1`. Every container address
is inside `10.163.<NNN>.0/24`. The nftables firewall
(`mpd-firewall.service`, installed by `mpd --vm-setup`) drops new
inbound connections into that subnet from any interface but the bridge
and `wg0`. So the container subnet is reachable by the VM itself and by
the developer's laptop (over the WireGuard overlay, or through sshd via
SOCKS/ProxyJump), and never from the LAN or a public network.

`net.ipv4.ip_forward=1` stays on because netavark needs it for the
container→internet masquerade. The firewall blocks forwarding *into* the
subnet only. The two are independent: outbound NAT keeps working,
inbound routing is denied. An mpd VM is therefore safe even on an
untrusted network. Its only exposed ports are sshd and WireGuard, plus
`tcp/3389` on a VM where you ran `rdp-start`. See `docs/networking.md`.

## Portal security

The portal at `https://<NNN>.mpd.test/` is a read-only status page
rendered by `mpd --web` (`go/internal/web/`), a VM process listening on
`127.0.0.1:8099`. caddy terminates TLS in front of it. It shows
projects, the runtime, databases, infra and extra services, and accepts
no input.

It shows each project's **database connection details**. These are
guessable anyway: `db.CreateFor` derives user, password and database
name from the project name (see "Database credentials" below).

**Rules for portal code** (`go/internal/web/`):

- No command execution, no form handling, no request parameters that
  trigger actions
- No API endpoints, no webhook receivers, no proxy functionality
- Read state only (`state.Store`, `current.Observer`, `srv`) — never
  write
- Display information only — never mutate state

The package doc states these rules. They hold with or without
authentication: a password would change who may look, not what the page
may do. There is no authentication today. Anything that can reach the
gateway `.1` can read it: the laptop over the overlay or the SOCKS
tunnel, and project code running in a runtime. It is not reachable from
the LAN.

## TLS and the certificate authority

The root CA is generated on the host by `mpd-virt` (separate
orchestrator, separate repo) and its private key stays there. A VM
receives a **per-VM intermediate**, signed by that root and
name-constrained to the VM's own zone. The in-VM `mpd` binary uses it to
sign the per-project certs and the VM's own service cert.

Two certificates are in play inside a VM, and they are not the same
thing. The **anchor** is what the VM's trust stores trust. The
**signer** is what leaf certificates are signed with:

```
mpd Root CA                        key: workstation only, never copied
  permitted;DNS:mpd.test
  └── mpd VM 126 CA                key: on VM 126
        permitted;DNS:126.mpd.test
        └── 126.mpd.test, m45.126.mpd.test, …   signed inside the VM
```

`cert.ResolveSigner` decides which case a given VM is in:

| Provisioned by                   | Anchor                           | Signer                      | Root key in the VM? |
|----------------------------------|----------------------------------|-----------------------------|---------------------|
| `mpd-virt` (macOS or Linux host) | `rootCA.pem`                     | zone-constrained `vmCA.pem` | **No**              |
| sandbox / no CA material         | self-signed, generated in the VM | the same certificate        | Yes — it made it    |

Only the last row has a VM holding a CA key that can sign for the whole
`mpd.test` tree, and there the VM generated that CA itself. There is no
separate root whose key could have been kept back. Anchor and signer are
one certificate, so the chain has one element and nothing extra is sent
in the handshake.

### CA properties

| Property                | Value                                                                           |
|-------------------------|---------------------------------------------------------------------------------|
| Root CA (host)          | `~/.mpd-virt/conf/caroot/rootCA.pem` + `rootCA-key.pem` (on the host)           |
| Per-VM CA (host)        | `~/.mpd-virt/<NNN>/ca/vmCA.pem` + `vmCA-key.pem`                                |
| In-VM location          | `/var/lib/mpd/conf/caroot/` — anchor `rootCA.pem`, signer `vmCA.pem`/`-key.pem` |
| Root CA private key     | Never leaves the workstation on the `mpd-virt` path (see table above)           |
| Root CA validity        | 365 days via `mpd-virt`; 10 years when generated in-VM (sandbox)                |
| Per-VM CA validity      | ≤ 397 days, capped by the root's remaining life                                 |
| Leaf cert validity      | ≤ 397 days (macOS requires < 398), capped by the signer's remaining life        |
| Root name constraints   | `permitted;DNS:mpd.test`                                                        |
| Per-VM name constraints | `permitted;DNS:<NNN>.mpd.test`, `pathlen:0`                                     |
| Key permissions         | every private key mode `0600`                                                   |
| macOS trust             | System Keychain via `security add-trusted-cert -d -r trustRoot` — root only     |

**Name constraints** limit the root to `*.mpd.test`, so even a
compromised key cannot sign for a real domain (e.g. `google.com`). RFC
5280 constraints combine down the chain, so the per-VM intermediate is
limited twice: a leaf for another VM's zone is rejected by the
intermediate's own constraint, and a leaf for a public domain by the
root's. Both the macOS Security framework and OpenSSL enforce this.

That second constraint is what makes it safe to give `*.mpd.test` names
to machines that are not development VMs. Rooting a VM lets an attacker
forge names in a zone they already control, and nothing else.

**Nothing outlives its issuer.** The per-VM CA and every leaf are capped
by the remaining life of the certificate above them. A certificate valid
past its issuer's expiry fails in a confusing way: the chain breaks on
the issuer's date while the leaf still looks valid.

**Host-only trust rule.** CAs flow host → VM only. The host trust store
only ever trusts certificates the host generated itself. `mpd-virt`
generates the CA on the host *before* creating the VM and pushes it into
the VM at provisioning time.

### Certificate types

| Certificate | SAN                                                                        | Stored at                                    | Lifetime                                    |
|-------------|----------------------------------------------------------------------------|----------------------------------------------|---------------------------------------------|
| Per-project | `<project>.<NNN>.mpd.test` (+ `behat.<project>.<NNN>.mpd.test` for moodle) | `/srv/meta/<project>/cert.pem` (data volume) | Survives runtime recreation                 |
| Service     | `<NNN>.mpd.test` (the zone apex — its single SAN)                          | `/var/lib/mpd/conf/service/`                 | Regenerated by `--vm-setup` when CA changes |

The in-runtime caddy serves the per-project certs. Their keys are
`0600` and dev-owned, which is why `mpd-caddy.service` runs as the dev
user. The VM's caddy serves the service cert for the portal. Extra
service containers have no certificates: they are plain HTTP inside the
trust boundary (see "Intentional compromises").

The CA private key **never enters any container**. Certificates are
signed inside the VM (in the `mpd` binary's host process) and written
into the data volume or copied into containers.

### CA trust inside containers

The runtime gets the CA public cert (`rootCA.pem`) installed into its
system trust store during provisioning (`update-ca-certificates`). This
allows:

- `curl https://<project>.<NNN>.mpd.test/` from inside the runtime (no
  `--insecure` needed)
- Composer and npm HTTPS operations against `*.mpd.test` URLs

## The runtime control socket

`mpd` works from inside the runtime container: it forwards commands to
the VM over a Unix socket and the VM runs them. This is a convenience,
not a security feature. The runtime already has passwordless sudo and
the whole data volume, so the socket adds nothing an attacker in the
runtime could not reach anyway. The VM is the boundary (see "Where the
isolation actually comes from"); run a separate VM per customer or
trust level.

What the socket refuses is there to block accidents, not attacks:

- The VM lifecycle (`--vm-setup`, `--vm-upgrade`, `--vm-start`,
  `--vm-stop`, `--vm-restart`), rebuilding or restoring the runtime you
  are standing in (`--runtime-rebuild`, `--runtime-restore`), starting
  the `--web` / `--control` daemons, and `run`. All of these would pull
  the floor out from under the caller, or loop back to where it already
  is. `--vm-status` is read-only and is forwarded.
- A working directory outside `/srv` is replaced by `/srv`: `/srv` is
  the one tree at the same path on both sides, while `/home/<user>` is
  a different directory on the VM. Relative paths are refused.

Everything else — projects, databases (`--db-*`), extra services
(`--service-*`), runtime backups — is forwarded as is. Deleting a
project from inside the runtime deletes it for real.

The daemon (`mpd --control`, `mpd-control.service`) runs as a systemd
user unit with no privileges of its own. A forwarded command gets
privilege the same way a VM terminal does, with per-operation `sudo` in
the child. The child takes the state lock itself, so commands from both
sides serialise.

## Authentication

### SSH

Two SSH endpoints, both pubkey-only:

- **The VM** (`tcp/22` on its LAN IP) — management shell, the ProxyJump
  base for the runtime, and the SOCKS fallback. Root login disabled.
- **The runtime container** (`runtime.<NNN>.mpd.test`) — full dev shell,
  passwordless sudo. The runtime has the same dev user as the VM (name
  and uid, so `/srv` has one owner on both sides), with the VM's
  `~/.ssh/authorized_keys` copied in. Root login disabled.

File transfer has no endpoint of its own. The data volume is mounted on
the VM at `/srv`, so `/srv/backups/` is reached over the VM's own sshd,
the connection the developer already has.

The runtime is reached via SSH ProxyJump through the VM's sshd, using the
single alias mpd-virt writes (`mpd-<NNN>`). The jump lands on the VM's
sshd, which reaches the runtime over the internal bridge, so it needs no
overlay. No published ports on the VM's LAN address.

SSH agent forwarding (`ssh -A`) is optional, for sessions that need
host-agent-backed git/auth inside the container. It passes the
developer's key into the container for the session. The private key
never touches the container filesystem.

**Lost the laptop's private key?** Reach the VM through the hypervisor's
own guest console (or single-user mode) and replace
`~/.ssh/authorized_keys` with your new public key directly. There is no
network path in without a trusted key.

### RDP (opt-in, off by default)

`rdp-start` opens `tcp/3389` onto the VM's GNOME desktop for devices
that cannot run an SSH tunnel or the WireGuard overlay. xrdp
authenticates through PAM, so this endpoint is protected by the dev
user's Unix **password**. It is the only password-authenticated endpoint
mpd ever opens, and the reason the tool prompts for one: on an mpd VM
that account normally has no password at all.

To limit the blast radius to RDP alone, `rdp-start` writes
`/etc/ssh/sshd_config.d/20-mpd-no-ssh-password.conf`
(`PasswordAuthentication no`) once it has confirmed a key is installed,
so the new password cannot be used against sshd. When there is no key
yet it warns instead of locking you out. (A managed or prepared VM
normally already has the stricter `10-mpd.conf` from
`bootstrap/15-secure-ssh.sh`, which also disables root over SSH. The two
drop-ins agree and coexist.)

`rdp-stop` disables the service and the port. The password stays set for
the next `rdp-start`. `sudo passwd -l <user>` clears it, on a headless VM
only: a locked password also fails at the GNOME greeter.

### Database credentials

Dev-only credentials, not designed for security:

| Engine     | Per-project                | Superuser               |
|------------|----------------------------|-------------------------|
| PostgreSQL | user/pass/db = `<project>` | `postgres` / `postgres` |
| MariaDB    | user/pass/db = `<project>` | `root` / `root`         |
| MySQL      | user/pass/db = `<project>` | `root` / `root`         |

Databases are reachable from inside containers, and from the laptop only
by tunnelling through the VM's sshd (`ssh -L`) or the SOCKS proxy. The
firewall seals their container IPs from direct outside access. No DB
ports are exposed on the VM's LAN address.

## Key and credential storage

| Secret                | Location                                                                                    | Permissions        |
|-----------------------|---------------------------------------------------------------------------------------------|--------------------|
| Root CA private key   | `~/.mpd-virt/conf/caroot/rootCA-key.pem` (host only)                                        | `0600`             |
| Per-VM CA private key | `~/.mpd-virt/<NNN>/ca/vmCA-key.pem` (host) and `/var/lib/mpd/conf/caroot/vmCA-key.pem` (VM) | `0600`             |
| Per-project TLS keys  | `/srv/meta/<project>/key.pem`                                                               | Inside data volume |
| SSH authorized keys   | `/home/<user>/.ssh/authorized_keys`                                                         | Inside containers  |

The per-VM CA key is the one piece of CA material that is *meant* to
travel. It is constrained to that VM's zone, so its blast radius is the
VM it already lives on.

`mpd-virt uninstall` on the host stops the VMs (they are kept), removes
the host-side state and ssh-config blocks, and tells you how to remove
the CA from the Keychain. The host's `~/.mpd-virt/conf/caroot/` is kept
on purpose, so a re-setup reuses the same CA. In-VM state lives under
`/var/lib/mpd/` on the VM filesystem and is wiped when the VM itself is
deleted.

## Container isolation

All containers run under rootful Podman inside the VM. They share one
Podman network (`mpd-internal`) and one data volume (`mpd-data-volume`,
mounted at `/srv/`).

**Containers are not isolated from each other.** Any container can reach
any other container on `mpd-internal`, and the runtime mounts the whole
data volume: a process in it can read and write every project's source,
dataroot and backups. This is intentional for a single-developer
environment.

Container IPs are unreachable from the LAN: the in-VM firewall drops
routing into `10.163.<NNN>.0/24` from every interface except the bridge
and `wg0`. The developer's laptop reaches the whole subnet, via the
WireGuard overlay (mpd-proxy routes the `/24` through `wg0`) or via
SOCKS/ProxyJump through sshd on the VM.

## What mpd does NOT protect against

- **Malicious code in projects, *within the VM***: a repo with a
  malicious `composer install` post-script or npm lifecycle hook runs
  with full access to `/srv/` and the network, and can reach every other
  container. mpd adds no sandbox *inside* the VM. The VM is the sandbox.
  Compared with running `composer install` directly on your workstation
  this is a large improvement. Compared with a hardened per-project jail
  it is no protection at all. Assume anything that runs in a runtime
  owns the whole VM.
- **Compromised runtime containers**: containers have passwordless sudo
  and network access. A compromised container can reach all other
  containers and all data in the volume.
- **Physical access to the host**: anyone with access to
  `~/.mpd-virt/conf/` can read the CA key.

## Intentional compromises

These are deliberate tradeoffs: security relaxed in exchange for dev
ergonomics. All are safe in a single-developer local environment and
would be unacceptable in production.

| Compromise                            | Rationale                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
|---------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Passwordless `sudo` inside containers | Dev needs root for package installs, service restarts, config changes. No security boundary between the dev user and root inside a container.                                                                                                                                                                                                                                                                                                                                     |
| No web-server access control          | Every project is fully accessible through the in-runtime caddy: no auth, no IP restrictions. Access control is at the network level (the firewall seals the container subnet from the LAN; it is reached only over the developer's authenticated WireGuard/SSH), not at the web server.                                                                                                                                                                                           |
| Extra services are plain HTTP         | mailpit, adminer and seleniumv1 serve unencrypted HTTP at their own container addresses (`http://<name>.svc.<NNN>.mpd.test:<port>/`). They are reachable only across the sealed subnet, over the developer's WireGuard overlay or SOCKS tunnel (both encrypted), so the plaintext hop exists only inside the trust boundary.                                                                                                                                                      |
| PostgreSQL `synchronous_commit=off`   | Trades a little crash durability for speed: an unclean shutdown loses at most the last fraction of a second of commits. Bounded, and no corruption. `full_page_writes` stays ON on purpose: turning it off risks a torn page postgres cannot repair, and unclean shutdowns are routine here (an OOM'd VM never runs `mpd --vm-stop`, so the graceful-shutdown hooks never fire). Losing seconds of work is an acceptable dev tradeoff; losing the database is not.                |
| Behat uses a separate subdomain       | Behat runs on `behat.<project>.<NNN>.mpd.test` (HTTPS, same cert). The seleniumv1 service is a stock upstream image without the mpd CA, so the generated behat config sets `acceptInsecureCerts` for its browser sessions.                                                                                                                                                                                                                                                        |
| Shared data volume across containers  | The runtime and the DB containers mount `mpd-data-volume` at `/srv/`. A process in one container can read/write data belonging to another. This is the single-volume design: simplicity over isolation.                                                                                                                                                                                                                                                                           |
| SSH agent forwarding                  | `ssh -A` passes the developer's key into the container. Any process running as the dev user inside the container can use the forwarded key for the duration of the session. Standard SSH risk, same as forwarding into any remote server.                                                                                                                                                                                                                                         |
| RDP on `tcp/3389` (`rdp-start`)       | A third open port, and the only one authenticated by a password instead of a key (xrdp has PAM and nothing else). Off unless you run `rdp-start`, removed again by `rdp-stop`. `rdp-start` sets the dev user's password, then turns SSH password authentication off, so that password works for RDP and nothing more. Expose it on a host-only network or behind a bastion / zero-trust tunnel. The desktop behind it has the same full access to `/srv/` as any shell in the VM. |
| Dev database credentials              | User, password and database name all equal the project name. Superuser passwords are `postgres`/`root`. See "Database credentials" above.                                                                                                                                                                                                                                                                                                                                         |

## Design decisions

**Why dev credentials instead of random passwords?** mpd is a local dev
tool. Strong DB passwords add friction (copy-pasting into PhpStorm,
Adminer, config files) with no security benefit, because the DB is only
reachable from the developer's own machine. The project name as
user/pass/db makes setup trivial.

**Why a private CA instead of self-signed certs?** One CA trust
operation, then every project and runtime gets a trusted certificate
automatically. No browser warnings, no `--insecure` flags, no per-cert
trust clicks. The same root also signs certificates for other machines
on the LAN (`mpd-virt server add`): a Proxmox host, a Forgejo, anything
else under `*.mpd.test`, so one trusted root covers the whole local
setup. Name constraints keep it limited to `mpd.test`.

**Why a WireGuard overlay (mpd-proxy) for daily use?** The laptop needs
each VM's whole container subnet (project URLs are served at container
IPs), while the subnet must *not* be exposed on the LAN. mpd-proxy runs
one WireGuard `utun` on the laptop and adds each VM as a peer routing
`10.163.<NNN>.0/24`, with one split-DNS resolver. Several VMs are
reachable at once through one encrypted tunnel, with no per-VM route or
`/etc/resolver` file, and it coexists with a corporate VPN. It is the
daily driver for anyone running more than one VM. The LAN side stays
sealed by the in-VM firewall, which exempts only the bridge and `wg0`.

**Why SOCKS-over-SSH as the simple path?** mpd-proxy needs `sudo` (it
creates a utun), which is more than an occasional user needs. `ssh -N
mpd-<NNN>-socks` opens a SOCKS5 proxy on `127.0.0.1:1080` that tunnels
through the VM over plain SSH. Point a dedicated browser at it (remote
DNS on) and `*.mpd.test` resolves and serves via the VM's own caddy: no
sudo, no overlay, one VM at a time. Trust the CA in that browser (or the
System Keychain) and HTTPS works. **This is the recommended starting
point for a new developer.** Move to mpd-proxy when you run VMs every
day.
