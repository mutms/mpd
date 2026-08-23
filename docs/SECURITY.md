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
  the runtime, dev-grade DB credentials, no isolation between
  containers, a shared data volume — these buy ergonomics inside a
  boundary that is already assumed to be hostile.
- **The boundary that matters is VM → workstation.** That direction is
  one-way by construction: the root CA private key never enters a VM —
  what a VM gets is its own intermediate, which cannot name anything
  outside that VM's DNS zone — SSH runs workstation → VM with no keys
  pointing back, and no container port is published to the workstation's
  own network.

### Where the isolation actually comes from

Ranked, weakest first:

1. **Podman containers — no security value.** The runtime has
   passwordless sudo; containers share one data volume, sit on one
   network with no isolation between them, and are provisioned by
   scripts that run as root during bootstrap. Containers exist here for
   *reproducibility and convenience*, not confinement. Do not reason about them as a security
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

Three things follow for mpd, because its runtime is long lived —
nothing resets it between projects, and mpd offers no scrubbing step
(see `docs/ROADMAP.md`):

- **Assume persistent compromise.** A runtime that executes a malicious
  postinstall keeps it. If you suspect one, `mpd --runtime-rebuild`
  replaces it wholesale — and think before running `--runtime-restore`
  afterwards, since the backup carries home-directory state from the
  suspect runtime back in.
- **Keep credentials out of the VM.** This is why the root CA private key
  stays on the workstation and the VM gets only a zone-constrained
  intermediate, and why it is worth resisting the temptation to park API
  tokens in `mpd-virt.env` for convenience.
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
  │  reaches the VM two ways, both cryptographic:
  │    • WireGuard overlay (udp/51820, via mpd-proxy) → the whole container /24
  │    • SSH (tcp/22) → management, ProxyJump into the runtime, SOCKS fallback
  │
VM host (Debian Trixie)     exposes ONLY :22 (sshd) + :51820 (wg) on its LAN IP
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
DNS zone (<NNN>.mpd.test) — see docs/NETWORKING.md.
```

**The container subnet is not reachable from the LAN or the public side
of the VM.** The developer's laptop reaches the whole /24 — the
WireGuard overlay carries it (`mpd-virt` sets the peer's AllowedIPs to
the /24), and SOCKS/ProxyJump reach it through sshd — but an in-VM
nftables firewall (`mpd-firewall.service`, installed by `mpd
--vm-setup`) drops any new forwarded connection into
`10.163.<NNN>.0/24` from an interface other than the bridge itself and
`wg0`. Container→internet (masquerade) is untouched.

So the VM's exposed attack surface is exactly **two ports, both
cryptographically authenticated**:

- **`udp/51820` — WireGuard.** mpd-proxy on the laptop is the only
  authorised peer; wg silently drops anything else.
- **`tcp/22` — SSH.** Pubkey-only, root login disabled.

Everything else — portal, project HTTPS, databases, extra services, the
runtime — lives behind those two doors: over the overlay or a SOCKS
tunnel through sshd, shells via ProxyJump through sshd. Nothing is
published on the VM's LAN address.

**The one opt-in third port: `tcp/3389` — RDP.** `rdp-start` installs and
starts xrdp so the VM's GNOME desktop can be reached from a device that
can hold neither an SSH tunnel nor the WireGuard overlay — a tablet. It
is off after every bootstrap, it is never enabled on your behalf, and
`rdp-stop` removes it from the boot path again. It breaks the property
above in one specific way: xrdp authenticates through PAM, so the door is
held by the dev user's **password**, not a key. `rdp-start` narrows that
where it can — it turns SSH password authentication off (once a key is
installed) so the new password is an RDP credential only. Treat the port
accordingly: a hypervisor's host-only network, or a private network
reached through a bastion or a zero-trust tunnel. Not the open internet.
See "Intentional compromises".

**Topology therefore no longer matters — and that is the security win.**
Because the only things reachable across the network are wg and ssh, a VM
is safe to run anywhere the laptop can reach it by IP:

- **Desktop hypervisor** (Parallels, UTM, Apple container, libvirt) — a NAT'd host-only
  network the laptop owns.
- **LAN- or datacentre-hosted** (Proxmox, a cloud VM) — a routable IP,
  even a public one. A LAN neighbour or an internet scanner sees only wg
  (silent) and ssh (pubkey-only); the container subnet is invisible to
  them. This is **preferred**: the untrusted environment moves off the
  workstation entirely, and the hardened surface makes the exposure safe.

Under the previous routed-subnet model any host that added the route
reached the portal and DBs. That is no longer true: caddy no longer binds
the LAN IP, and the firewall drops inbound routing into the subnet.

**Who is trusted**: the developer. They have full access to
everything — SSH into the runtime, read/write all source code, admin
access to all databases, root via passwordless sudo inside containers.

**Who is not trusted**: anyone else — *and* everything the developer
runs inside a VM. Project code, dependencies, and agents are untrusted
guests that happen to be given a comfortable cage.

## Network access control

Nothing is published on the VM's own LAN address. caddy and dnsmasq bind
only the podman bridge gateway `10.163.<NNN>.1`, every container address
is inside `10.163.<NNN>.0/24`, and an nftables firewall
(`mpd-firewall.service`, installed by `mpd --vm-setup`) drops new inbound
connections into that subnet from any interface but the bridge and
`wg0`. So the container subnet is reachable by the VM itself and by the
developer's laptop — over the WireGuard overlay, or through sshd via
SOCKS/ProxyJump — never from the LAN or a public network.

`net.ipv4.ip_forward=1` stays on (netavark needs it for the
container→internet masquerade), but forwarding *into* the subnet is what
the firewall blocks. The two are independent: outbound NAT keeps working,
inbound routing is denied — so an mpd VM is safe even on an untrusted
network, its only exposed ports being sshd and WireGuard (plus `tcp/3389`
on a VM where you ran `rdp-start`). See `docs/NETWORKING.md`.

## Portal security

The portal at `https://<NNN>.mpd.test/` is a read-only status page
rendered by `mpd --web` (`go/internal/web/`), a VM process listening on
`127.0.0.1:8099`. caddy terminates TLS in front of it. It displays
projects, the runtime, databases, infra and extra services, and accepts
no input.

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
is allowed to do. There is no authentication today; anything that can reach the gateway
`.1` can read it — the laptop over the overlay or the SOCKS tunnel, and
project code running in a runtime (which reaches the gateway from inside).
It is not reachable from the LAN.

## TLS and the certificate authority

The root CA is generated on the host by `mpd-virt` (separate
orchestrator, separate repo) and its private key stays there. What a VM
receives is a **per-VM intermediate**, signed by that root and
name-constrained to the VM's own zone, which the in-VM `mpd` binary uses
to sign the per-project certs and the VM's own service cert.

Two certificates are therefore in play inside a VM and they are not the
same thing. The **anchor** is what the VM's trust stores trust; the
**signer** is what leaf certificates are actually signed with:

```
mpd Root CA                        key: workstation only, never copied
  permitted;DNS:mpd.test
  └── mpd VM 126 CA                key: on VM 126
        permitted;DNS:126.mpd.test
        └── 126.mpd.test, m45.126.mpd.test, …   signed inside the VM
```

Every host platform provisions this way. `cert.ResolveSigner` decides
which case a given VM is in:

| Provisioned by            | Anchor        | Signer                      | Root key in the VM? |
|---------------------------|---------------|-----------------------------|---------------------|
| `mpd-virt` (macOS or Linux host) | `rootCA.pem` | zone-constrained `vmCA.pem` | **No**          |
| sandbox / no CA material  | self-signed, generated in the VM | the same certificate | Yes — it made it |

Only the last row still has a VM holding a CA key that can sign for the
whole `mpd.test` tree, and there the VM generated that CA itself — there
is no separate root whose key could have been withheld. Anchor and signer
are one certificate, so the chain is one long and nothing extra is sent
in the handshake.

### CA properties

| Property                  | Value                                                                     |
|---------------------------|---------------------------------------------------------------------------|
| Root CA (host)            | `~/.mpd-virt/conf/caroot/rootCA.pem` + `rootCA-key.pem` (on the host)      |
| Per-VM CA (host)          | `~/.mpd-virt/<NNN>/ca/vmCA.pem` + `vmCA-key.pem`                           |
| In-VM location            | `/var/lib/mpd/conf/caroot/` — anchor `rootCA.pem`, signer `vmCA.pem`/`-key.pem` |
| Root CA private key       | Never leaves the workstation on the `mpd-virt` path (see table above)     |
| Root CA validity          | 365 days via `mpd-virt`; 10 years when generated by `setup/*` or in-VM    |
| Per-VM CA validity        | ≤ 397 days, capped by the root's remaining life                           |
| Leaf cert validity        | ≤ 397 days (macOS requires < 398), capped by the signer's remaining life  |
| Root name constraints     | `permitted;DNS:mpd.test`                                                  |
| Per-VM name constraints   | `permitted;DNS:<NNN>.mpd.test`, `pathlen:0`                               |
| Key permissions           | every private key mode `0600`                                             |
| macOS trust               | System Keychain via `security add-trusted-cert -d -r trustRoot` — root only |

**Name constraints** limit the root to signing for `*.mpd.test` only, so
even a compromised key cannot sign for a real domain (e.g.
`google.com`). RFC 5280 constraints compose down the chain, so the per-VM
intermediate is limited twice over: a leaf it signs for another VM's zone
is rejected by the intermediate's own constraint, and one for a public
domain by the root's. Both the macOS Security framework and OpenSSL
enforce this.

That second constraint is what makes it safe to give `*.mpd.test` names
to machines that are not development VMs: rooting a VM buys the ability
to forge names in a zone the attacker already controls, and nothing else.

**Nothing outlives its issuer.** Both the per-VM CA and every leaf are
capped by however long the certificate above them has left. A
certificate valid past its issuer's expiry does not degrade gracefully —
the chain fails on the issuer's date while the leaf still reads as
valid, which is a confusing failure to debug.

**Host-only trust rule.** CAs flow host → VM only. The macOS keychain
only ever trusts certificates the host generated itself. `mpd-virt`
generates the CA on the host *before* creating the VM and pushes it
into the VM at provisioning time.

### Certificate types

| Certificate | SAN                                                            | Stored at                                    | Lifetime                                 |
|-------------|----------------------------------------------------------------|----------------------------------------------|------------------------------------------|
| Per-project | `<project>.<NNN>.mpd.test` (+ `behat.<project>.<NNN>.mpd.test` for moodle) | `/srv/meta/<project>/cert.pem` (data volume) | Survives runtime recreation              |
| Service     | `<NNN>.mpd.test` (the zone apex — its single SAN)              | `/var/lib/mpd/conf/service/`                 | Regenerated by `--vm-setup` when CA changes |

The per-project certs are what the in-runtime caddy serves (their keys
are `0600`, dev-owned — the reason `mpd-caddy.service` runs as the dev
user); the service cert is what the VM's caddy serves for the portal.
Extra service containers have no certificates — they are plain HTTP
inside the trust boundary (see "Intentional compromises").

The CA private key **never enters any container**. Certificates are
signed inside the VM (in the `mpd` binary's host process) and written
into the data volume or copied into containers.

### CA trust inside containers

The runtime gets the CA public cert (`rootCA.pem`) installed into its
system trust store during provisioning (`update-ca-certificates`).
This allows:

- `curl https://<project>.<NNN>.mpd.test/` from inside the runtime (no
  `--insecure` needed)
- Composer and npm HTTPS operations against `*.mpd.test` URLs

## The runtime control socket

`mpd` works from inside a runtime container: it forwards commands to the
VM over a Unix socket and the VM runs them. This deliberately widens what
a runtime can reach, so the trade is recorded here rather than left
implicit.

**What changes.** Before, a compromised or confused process inside the
runtime — including an AI agent, which runs there with passwordless sudo
— could write anything under `/srv` but could not touch the control
plane: no podman socket, no `/var/lib/mpd/conf`, no
`/var/lib/mpd/state`. It can now drive most of mpd through the socket:
create, configure, start, stop, reset and delete **projects**, manage
**databases** (`--db-*`) and **extra services** (`--service-*`), and take
a **runtime backup**. Deleting a project destroys its database, dataroot
and source tree, and `--db-delete` / `--service-purge` are likewise
destructive, so this is a real increase in blast radius, not a formality.
The trade is deliberate: a single runtime has one owner, so these are the
developer's own resources, and reaching them without a second VM terminal
is the point.

**What does not change.** It cannot change the VM's lifecycle
(`--vm-setup`/`--vm-upgrade`/`--vm-start`/`--vm-stop`/`--vm-restart`), tear
down or restore the runtime it is calling from (`--runtime-rebuild`,
`--runtime-restore`), or start a control-plane daemon (`--web`,
`--control`) — those are refused — and it cannot ask the VM to execute an
arbitrary command (`run` loops back to where the caller already is). The
line is "don't terminate the runtime you are standing in": read-only
introspection (`--vm-status`) forwards.

Four properties carry that:

1. **Bounded denylist.** The daemon never runs a program named in a
   request. It refuses a small, compiled-in set — the mutating `--vm-*`
   lifecycle flags (all but the read-only `--vm-status`),
   `--runtime-rebuild`/`--runtime-restore`, the `--web`/`--control`
   daemons, plus the `run` verb — and forwards everything else to the mpd
   binary it spawns, whose path comes from
   `internal/exec`'s absolute-path allow-list. A request selects a verb
   or flag; it cannot select an executable. A pinning test cross-checks
   the denylist against the full flag set (`cli.GlobalFlags`), so adding
   a flag is a deliberate decision about runtime exposure rather than a
   silent grant.
2. **Identity from the channel.** The runtime's socket is bind-mounted
   read-only into that runtime alone, so the caller's identity is the
   socket that accepted the connection — unforgeable, because the
   client never asserts it. `SO_PEERCRED` could not carry identity
   here: the runtime runs the same UID-matched dev user as the VM, so
   peer credentials distinguish nothing. They still help as a second
   layer — the socket is mode `0660` and dev-user-owned, and the kernel
   enforces that across the container boundary.
3. **Context validated, not believed.** Most verbs infer their target
   project from the working directory, so a cwd taken on faith would be a
   way to name someone else's project. A cwd is usable only inside
   `/srv`, the one tree at the same path on both sides; anywhere else the
   command still runs but from `/srv`, because `/home/<user>` exists on
   the VM too and is a *different* directory there. Relative or
   non-clean paths are refused outright.
4. **Bounded authority.** With a single runtime there is no
   cross-runtime ownership left to check, so a runtime may drive
   projects, databases and services — its own developer's world — but
   not the machine that world runs on (the mutating `--vm-*` lifecycle),
   nor the runtime lifecycle it depends on
   (`--runtime-rebuild`/`--runtime-restore`).
   What remains on `init` is that a declared `--type` must name a type
   the asset tree actually defines (`moodle`, `astro`) — an undeclared
   type is left for the child to infer, same as on the VM.

`run` is refused rather than scoped. It is arbitrary execution by
design, and from inside the runtime it would merely loop back to where
the caller already is: runtime → VM → the same runtime.

**Turning it off.** Set `MPD_RUNTIME_CONTROL=off` in
`/var/lib/mpd/env/mpd-virt.env`. Read per request, so it takes effect on
the next command with no restart; only an explicit `off`/`false`/`0`/`no`
disables it, so a typo cannot silently break mpd inside the runtime.

That file is normally authored on the Mac and pushed into every VM, so
setting the switch there sets it for all of them at once — and it means
the workstation, not the VM, decides this VM's posture. That is the same
direction the CA travels (host → VM, §"Host-only trust rule"), and it is
the direction that holds: nothing inside a VM can reach back and change
what the Mac pushes. The runtime cannot edit the file either — the env
directory is mounted read-only into the container. Set it per VM by
editing the in-VM copy instead, accepting that the next
`mpd-virt start`/`update` overwrites it.

The daemon (`mpd --control`, `mpd-control.service`) runs as a **systemd
user unit with no privileges of its own**. A forwarded verb acquires
privilege the same way a VM terminal does — per-operation `sudo` inside
the child — and the child takes the state lock itself, so concurrent
commands serialise whichever side they came from.

## Authentication

### SSH

Two SSH endpoints, both pubkey-only:

- **The VM** (`tcp/22` on its LAN IP) — management shell, the ProxyJump
  base for the runtime, and the SOCKS fallback. Root login disabled.
- **The runtime container** (`runtime.<NNN>.mpd.test`) — full dev
  shell, passwordless sudo, the developer's UID. The runtime creates
  a user account matching the developer's username and UID; the public
  key from `~/.ssh/authorized_keys` is propagated into the container.
  Root login disabled.

File transfer has no endpoint of its own. The data volume is mounted on
the VM at `/srv`, so `/srv/backups/` is reached over the VM's own sshd —
the connection the developer already has.

Reached via SSH ProxyJump through the VM's sshd — the single alias
mpd-virt writes (`mpd-<NNN>`). The jump lands on the VM's sshd,
which reaches the runtime over the internal bridge, so it needs no
overlay. No published ports on the VM's LAN address.

SSH agent forwarding (`ssh -A`) is optional, for sessions that need
host-agent-backed git/auth inside the container. It passes the
developer's key into the container for the session — the private key
never touches the container filesystem.

**Lost the laptop's private key?** Reach the VM through the hypervisor's
own guest console (or single-user mode) and replace
`~/.ssh/authorized_keys` with your new public key directly — there is no
network path in without a trusted key.

### RDP (opt-in, off by default)

`rdp-start` opens `tcp/3389` onto the VM's GNOME desktop for devices
that cannot run an SSH tunnel or the WireGuard overlay. xrdp
authenticates through PAM, so this endpoint is held by the dev user's
Unix **password** — the only password-authenticated door mpd ever opens,
and the reason the tool prompts for one: on an mpd VM that account
normally has none at all.

To keep the blast radius to RDP alone, `rdp-start` writes
`/etc/ssh/sshd_config.d/20-mpd-no-ssh-password.conf`
(`PasswordAuthentication no`) once it has confirmed a key is already
installed, so the new password cannot be replayed against sshd. It warns
instead of locking you out when there is no key yet. (A managed or
prepared VM normally already has `bootstrap/15-secure-ssh.sh`'s stricter
`10-mpd.conf` in place — root over SSH off as well; the two drop-ins
agree and coexist.)

`rdp-stop` disables the service and the port. The password stays set for
the next `rdp-start`; `sudo passwd -l <user>` clears it, on a headless VM
only — a locked password also fails at the GNOME greeter.

### Database credentials

Dev-only credentials — not designed for security:

| Engine     | Per-project                | Superuser               |
|------------|----------------------------|-------------------------|
| PostgreSQL | user/pass/db = `<project>` | `postgres` / `postgres` |
| MariaDB    | user/pass/db = `<project>` | `root` / `root`         |
| MySQL      | user/pass/db = `<project>` | `root` / `root`         |

Databases are reachable from inside containers, and from the laptop only
by tunnelling through the VM's sshd (`ssh -L`) or the SOCKS proxy — their
container IPs are sealed from direct outside access by the firewall. No DB
ports are exposed on the VM's LAN address.

## Key and credential storage

| Secret                  | Location                                       | Permissions       |
|-------------------------|------------------------------------------------|-------------------|
| Root CA private key     | `~/.mpd-virt/conf/caroot/rootCA-key.pem` (host only) | `0600`      |
| Per-VM CA private key   | `~/.mpd-virt/<NNN>/ca/vmCA-key.pem` (host) and `/var/lib/mpd/conf/caroot/vmCA-key.pem` (VM) | `0600` |
| Per-project TLS keys    | `/srv/meta/<project>/key.pem`                  | Inside data volume|
| SSH authorized keys     | `/home/<user>/.ssh/authorized_keys`            | Inside containers |

The per-VM CA key is the one piece of CA material that is *meant* to
travel. It is constrained to that VM's zone, so its blast radius is the
VM it already lives on.

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
reach any other container on `mpd-internal`, and the runtime mounts the
whole data volume — a process in it can read and write every project's
source, dataroot and backups. This is intentional for a
single-developer environment.

Container IPs are unreachable from the LAN: the in-VM firewall drops
routing into `10.163.<NNN>.0/24` from every interface except the bridge
itself and `wg0`. The developer's laptop, by contrast, reaches the whole
subnet — via the WireGuard overlay (mpd-proxy routes the `/24` through
`wg0`) or via SOCKS/ProxyJump through sshd on the VM.

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
| No web-server access control                                 | Every project is fully accessible through the in-runtime caddy — no auth, no IP restrictions. Access control is at the network level (the container subnet is sealed from the LAN by the firewall and reached only over the developer's authenticated WireGuard/SSH), not the web server level.                                                                                        |
| Extra services are plain HTTP                                | mailpit, adminer and seleniumv1 serve unencrypted HTTP at their own container addresses (`http://<name>.svc.<NNN>.mpd.test:<port>/`). They are reachable only across the sealed subnet — over the developer's WireGuard overlay or SOCKS tunnel, both encrypted transports — so the plaintext hop exists only inside the trust boundary.                       |
| PostgreSQL `synchronous_commit=off`                           | Trades a little crash durability for speed: an unclean shutdown loses at most the last fraction of a second of commits. Bounded, and no corruption. `full_page_writes` is deliberately left ON — turning it off risks a torn page postgres cannot repair, and unclean shutdowns are routine here (an OOM'd VM never runs `mpd --vm-stop`, so the graceful-shutdown hooks never fire). Losing seconds of work is an acceptable dev tradeoff; losing the database is not. |
| Behat uses a separate subdomain                              | Behat runs on `behat.<project>.<NNN>.mpd.test` (HTTPS, same cert). The seleniumv1 service is a stock upstream image without the mpd CA, so the generated behat config sets `acceptInsecureCerts` for its browser sessions.                          |
| Shared data volume across containers                         | The runtime and the DB containers mount `mpd-data-volume` at `/srv/`. A process in one container can read/write data belonging to another. This is the single-volume design — simplicity over isolation.                             |
| SSH agent forwarding                                         | `ssh -A` passes the developer's key into the container. Any process running as the dev user inside the container could use the forwarded key for the duration of the session. Standard SSH risk — same as forwarding into any remote server. |
| RDP on `tcp/3389` (`rdp-start`)                              | A third open port, and the only one authenticated by a password instead of a key — xrdp has PAM and nothing else. Off unless you run `rdp-start`, removed again by `rdp-stop`. `rdp-start` sets the dev user's password, then turns SSH password authentication off so that password buys RDP and nothing more. Expose it on a host-only network or behind a bastion / zero-trust tunnel; the desktop it fronts has the same full access to `/srv/` as any shell in the VM. |
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

**Why a WireGuard overlay (mpd-proxy) for daily use?** The laptop needs
each VM's whole container subnet — project URLs are served at container
IPs — while the subnet must *not* be exposed on the LAN. mpd-proxy runs
one WireGuard `utun` on the laptop and adds each VM as a peer routing
`10.163.<NNN>.0/24`, with one split-DNS resolver — so several VMs are
reachable at once through one encrypted tunnel, no per-VM route or
`/etc/resolver` file, coexisting with a corporate VPN. It is the daily
driver for anyone running more than one VM. (It supersedes the earlier
*flat* host-only WireGuard tunnel, which allowed only one active tunnel
and so reached one VM. The LAN side stays sealed by the in-VM firewall,
which exempts only the bridge and `wg0`.)

**Why SOCKS-over-SSH as the simple path?** mpd-proxy needs `sudo` (it
creates a utun) — more than an occasional user needs. `ssh -N
mpd-<NNN>-socks` opens a SOCKS5 proxy on `127.0.0.1:1080` that tunnels
through the VM over plain SSH; point a dedicated browser at it (remote DNS
on) and `*.mpd.test` resolves and serves via the VM's own caddy — no sudo,
no overlay, one VM at a time. Trust the CA in that browser (or the System
Keychain) and HTTPS just works. **This is the recommended starting point
for a new developer;** graduate to mpd-proxy when you run VMs every day.
