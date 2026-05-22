# Proposal: macOS host state model + WireGuard architecture

Two intertwined architectural decisions for the `mpd-virt-macos`
binary (lives in a separate repo) that drives mpd-machine VMs on
Parallels Desktop Pro. They're proposed together because each one's
design depends on the other:

1. **A two-directory state model** on the macOS host with clearly
   named owners, lifecycles, and migration boundaries.
2. **A WireGuard-based networking model** with persistent identity
   in `~/.mpd-virt/conf/` and zero daily sudo on the Mac.

Together they give the macOS host an end state where:

- Identity (CA, WG keys) is one persistent place, survives every VM
  rebuild.
- Bookkeeping is in one clearly-named directory, separate from
  identity.
- After initial setup, daily use needs no sudo and no
  `/etc/resolver/` files: WireGuard.app owns route + DNS, the user
  toggles the tunnel.
- Recreating a VM never requires re-importing WireGuard configs.

## Non-goals

- Linux/Windows host equivalents. The state-dir model has plausible
  analogues there but they're out of scope for this proposal.
- Cross-Mac sync of the WG identity. Each Mac is its own
  `mac.private`; multi-Mac users have multiple peers in their VM
  configs.
- WireGuard config exchange protocol. All configs are written by
  Swift on the Mac and pushed to the VM — no negotiation, no shared
  secret over the wire beyond what SCP already gives us.

## Part 1 — The one-directory state model on the host

### One sentence per owner

- **`~/.mpd-virt/`** — everything `mpd-virt` owns on the macOS host:
  identity (`conf/`) + per-VM bookkeeping. **The user owns it.**
  Identity material under `conf/` survives every `mpd-virt uninstall`.
- **`~/.mpd/`** is never created on the host — that path is
  exclusively the in-VM runtime state directory.

### Concrete directory layout (macOS host)

```
~/.mpd-virt/                          ← single host dir
├── conf/                             ← identity (survives uninstall)
│   ├── caroot/
│   │   ├── rootCA.pem
│   │   └── rootCA-key.pem
│   ├── wireguard/
│   │   ├── mac.private
│   │   ├── mac.public
│   │   └── machine/
│   │       └── <octet>/
│   │           ├── private
│   │           ├── public
│   │           ├── server.conf
│   │           └── client.conf       # imported into WG.app as "mpd-machine-<octet>"
│   └── service/
├── current.env                       # MPD_VM_OCTET pointer (orchestrator bookkeeping)
└── <octet>/
    └── env                           # MPD_VM_OCTET, NAME, IP, USER, UUID (diagnostic)
                                      # (future: per-VM logs, cache)
```

Inside any mpd-machine VM (Linux filesystem):

```
~/.mpd/                               ← in-VM state dir
├── conf/                             ← in-VM identity (pushed in by mpd-virt)
│   ├── caroot/rootCA.pem             ← public cert only; no private key on VM
│   ├── wireguard/mpd0.conf           ← wg-quick config the VM hosts (server side)
│   ├── service/
│   └── platform.env
└── (runtime state — machines/, projects/, …)
```

The `~/.mpd/` on the host is **not** present; the `~/.mpd/` inside the
VM is on a different filesystem and only exists in the VM.

### Lifecycle rules

| Action | What it touches |
|---|---|
| `mpd-virt setup` | Reads/writes `~/.mpd-virt/conf/` (idempotent). Creates the per-VM `~/.mpd-virt/<octet>/` and `current.env` pointer. |
| `mpd-virt uninstall` | Removes per-VM `~/.mpd-virt/<octet>/` and host-side networking. **Never** touches `~/.mpd-virt/conf/`. |
| `rm -rf ~/.mpd-virt/conf/` | User's manual nuclear option. Resets identity completely; next `mpd-virt setup` regenerates. |
| Recreate a VM at the same `<octet>` | `~/.mpd-virt/<octet>/env` is overwritten with the new VM's UUID + name snapshot. Reuses `~/.mpd-virt/conf/wireguard/machine/<octet>/` keys — WG.app tunnel still works. |

## Part 2 — WireGuard architecture

### Tunnel addressing

```
Mac (WireGuard.app)               VM (Debian Trixie)
────────────────────              ────────────────────
utun (10.164.0.1)        ←──UDP─→  wg0  (10.164.0.2)
                                    │
                                    │ AllowedIPs route forward to:
                                    ▼
                              containers @ 10.163.0.x
                              dnsmasq @ 10.163.0.3
```

**`10.164.0.0/30`** is the WG point-to-point tunnel subnet.

**DNS** via the tunnel: each `client.conf` includes `DNS = 10.163.0.3,
mpd.test`. When the tunnel is up, `*.mpd.test` resolves via dnsmasq
through the tunnel. **No `/etc/resolver/mpd.test` file** — WireGuard.app
owns DNS scope.

**AllowedIPs** on the Mac peer: `10.164.0.0/30, 10.163.0.0/24`. The
full container subnet is reachable via the tunnel; the host route to
`10.163.0.0/24` is owned by the tunnel. **No `sudo route add` step** —
WireGuard.app owns the route.

**Two convergent paths to containers.** The SSH config block (see
[`mpd-virt.md` §"SSH config block"](mpd-virt.md)) gives the user
`ssh mpd-machine-<octet>-php` via ProxyJump through the VM's Parallels
Shared static IP — that path works whether or not the WG tunnel is up.
Meanwhile WG provides full IP-level reachability to `10.163.0.0/24` for
everything else (browser HTTPS, ad-hoc TCP, port probes). Both work
simultaneously.

### Key management

All keypairs generated in Swift on the Mac via swift-crypto's
`Curve25519.KeyAgreement.PrivateKey`. The code lives in the `mpd-virt`
executable.

```swift
// MpdVirt.WireGuard
struct Keypair {
    let privateKey: String  // base64 of 32 raw bytes
    let publicKey: String   // base64 of 32 raw bytes

    static func generate() -> Keypair
    static func load(from dir: URL) throws -> Keypair?
    func save(to dir: URL) throws
    static func loadOrGenerate(at dir: URL) throws -> Keypair
}
```

`mac.{private,public}` is generated **once** the first time `mpd-virt`
calls `Keypair.loadOrGenerate(...)` for the Mac identity. Persisted at
`~/.mpd-virt/conf/wireguard/mac.{private,public}`. Every subsequent invocation
(a new VM at a different octet) reuses it.

`machine/<octet>/{private,public,server.conf,client.conf}` is generated
on first call per octet. Persisted at
`~/.mpd-virt/conf/wireguard/machine/<octet>/`. Every subsequent call reuses.

### Where private keys live (and don't)

- **`mac.private`** lives at `~/.mpd-virt/conf/wireguard/mac.private` on
  the Mac. Mode `0600`. Never transits anywhere.
- **`machine/<octet>/private`** (the VM's WG private key) lives at
  `~/.mpd-virt/conf/wireguard/machine/<octet>/private` on the Mac. The
  full `server.conf` (which embeds that private key inline) is pushed
  into the VM by `mpd-virt` during provisioning as
  `~/.mpd/conf/wireguard/mpd0.conf`. The in-VM `mpd --setup` then
  installs it to `/etc/wireguard/mpd0.conf` (root-owned, mode 0600).

The VM-side private key briefly transits the Mac orchestrator in memory
during generation and on the wire (encrypted over SSH). That's a small
concession relative to the convenience win: the same key can be
re-pushed into a recreated VM without regenerating, so WireGuard.app
configs stay valid across rebuilds.

### In-VM contract for `mpd --setup`

The split of responsibilities between mpd-virt (host) and mpd (in-VM):

| | mpd-virt (host, separate repo) | mpd `--setup` (in-VM) |
|---|---|---|
| Generate WG keys | yes | no |
| Render `server.conf` / `client.conf` | yes | no |
| Push `server.conf` into the VM | yes (SCP to `~/.mpd/conf/wireguard/mpd0.conf`) | — |
| Import `client.conf` into WireGuard.app | yes | — |
| Install the `wireguard` apt package | — | yes (idempotent) |
| Install conf to `/etc/wireguard/mpd0.conf` | — | yes (only if content differs) |
| Persist `net.ipv4.ip_forward=1` | — | yes (sysctl.d drop-in) |
| Enable + start `wg-quick@mpd0` | — | yes |
| Skip the WG step when no conf is present | — | yes (sandbox case) |

The in-VM step is **gated by the presence of `~/.mpd/conf/wireguard/mpd0.conf`**.
If the file isn't there (e.g. sandbox VM, or an mpd-machine VM where mpd-virt
hasn't pushed the config yet), the WG step is a clean no-op — `mpd --setup`
prints "no wireguard config present, skipping" and moves on.

### Daily user flow (steady state)

1. Host reboots. Parallels auto-resumes the active mpd-machine VM
   (Parallels' default).
2. User opens WireGuard.app, toggles the active tunnel on.
   **No password prompt** (WireGuard.app's system extension was
   authorized at install time).
3. `https://mpd.test/` resolves. SSH to the VM works. `mpd` (in the
   VM) is reachable via SSH.

**Zero sudo in the daily loop.** All sudo is at setup time.

### Recreation flow

User deletes VM `mpd-machine-159` in Parallels, decides to recreate it
from the template:

1. `mpd-virt setup`, picks octet `159` again.
2. Swift sees `~/.mpd-virt/conf/wireguard/machine/159/` exists → reuses the
   existing keypair + configs.
3. Clones template, provisions, **scp's the existing `server.conf`** into
   the new VM as `~/.mpd/conf/wireguard/mpd0.conf`. The in-VM `mpd --setup`
   then apt-installs `wireguard`, installs that file to
   `/etc/wireguard/mpd0.conf` (mode 0600 root:root), and enables
   `wg-quick@mpd0`.
4. **WireGuard.app's existing `mpd-machine-159` tunnel is untouched.** No
   re-import needed. The new VM has the same WG identity as the one that
   was deleted.

This is the whole point of persistent identity in `~/.mpd-virt/conf/`. The
VM is disposable; the WG keys are not.

### Switching between VMs

User has two mpd-machine VMs (octets `155` and `156`) cloned from the
template:

1. WireGuard.app shows `mpd-machine-155` and `mpd-machine-156` as two
   tunnels.
2. Both claim Mac end `10.164.0.1`, so only one can be active.
3. Toggling between them is the entire UX — no setup-script invocation,
   no IP collision handling, no host-state mutation.

### Initial setup (the only place sudo appears)

`mpd-virt setup` on a fresh Mac:

1. **One sudo prompt for the CA trust step**
   (`sudo security add-trusted-cert -d -r trustRoot -k
   /Library/Keychains/System.keychain <caroot/rootCA.pem>`). One time,
   never again.
2. **One-time admin auth for WireGuard.app's system extension** (macOS
   native flow, happens at first install of WireGuard.app from the App
   Store). Not mpd-virt's problem.

After that — including all VM clones, switches, recreations — **zero
sudo**. The daily-no-sudo property holds for all subsequent activity.

## Threat model

The model is "the Mac is the trust origin; the VM is disposable":

| Asset | Lives on | Compromise impact |
|---|---|---|
| mpd CA private key | Mac (`~/.mpd-virt/conf/caroot/`) | Can sign arbitrary `*.mpd.test` certs (name-constrained; limited blast radius) |
| `mac.private` (WG) | Mac (`~/.mpd-virt/conf/wireguard/`) | Can impersonate the Mac to any peer that trusts it |
| `machine/<octet>/private` (WG) | Mac (`~/.mpd-virt/conf/wireguard/`) + VM | Can impersonate that VM peer to the Mac. Briefly transits Mac in memory + over SSH during initial provisioning |
| SSH private key | Mac (`~/.ssh/`) | Root in any mpd-machine VM (dev user has passwordless sudo) |

A Mac compromise gives you everything. The VM-side WG private key
sitting on the Mac doesn't enlarge that — the SSH key already
implies VM root.

A *VM* compromise (e.g. via a malicious project) does not climb back
to the Mac: the Mac-side WG private key is not on the VM, the CA
private key is not on the VM (only the cert is), and SSH is one-way
(VM doesn't have keys to access the Mac).

## Open questions

- **Should `mac.private` be backed up?** Losing it means every WG.app
  tunnel needs re-generating + re-importing. Worth a
  `mpd-virt export-identity` / `import-identity` flow? Probably defer.
  Time Machine catches `~/.mpd-virt/conf/` by default if the user has it
  enabled.
- **Should `machine/<octet>/private` be regeneratable on demand?** A
  hypothetical `mpd-virt rotate-wireguard <octet>` verb would generate
  a new VM-side keypair, push it to the VM, rewrite `client.conf`,
  prompt the user to re-import. Not urgent.
- **Inside the mpd-machine VM, does the in-VM `mpd --setup` need any
  awareness of the host's WireGuard?** Probably not — the VM doesn't
  care about the tunnel; it just hosts `wg-quick@mpd0` as a systemd
  service that's enabled by mpd-virt's provisioning step.
