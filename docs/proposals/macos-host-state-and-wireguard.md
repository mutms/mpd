# Proposal: macOS host state model + WireGuard architecture

Two intertwined architectural decisions for the macOS host side of
mpd. They're proposed together because each one's design depends on
the other:

1. **A three-directory state model** on the macOS host with clearly
   named owners, lifecycles, and migration boundaries.
2. **A WireGuard-based networking model** for both `mpd-prl` and
   `mpd-desktop`, with persistent identity in `~/Developer/mpd/conf/`
   and zero daily sudo on the Mac.

Together they give the macOS host an end state where:

- Identity (CA, WG keys) is one persistent place, survives every
  uninstall and every VM rebuild.
- Each product's host-side bookkeeping is in its own clearly-named
  directory.
- After initial setup, daily use of mpd needs no sudo and no
  `/etc/resolver/` files: WireGuard.app owns route + DNS, the user
  toggles the tunnel.
- Recreating a VM or a Podman Desktop machine never requires re-importing
  WireGuard configs.

## Assumed starting state

This proposal assumes a **fully clean macOS host** at the moment
Phase A begins. Specifically:

- **No existing mpd-prl VMs in Parallels.** mpd-prl doesn't exist
  yet, so there can't be any.
- **No existing Podman Desktop machines** under mpd-desktop. If the
  user has previously used mpd-desktop, the Podman Desktop machine
  is removed (`podman machine rm`) before Phase A begins.
- **No `~/.mpd-machine/`**, **no `~/.mpd-desktop/`**, **no `~/.mpd/`**
  anywhere under the user's home. All three host-side state
  directories are wiped:
  ```
  rm -rf ~/.mpd-machine ~/.mpd-desktop ~/.mpd
  ```
- **No `~/Developer/mpd/conf/`** content from prior installs. The
  persistent identity dir is wiped too:
  ```
  rm -rf ~/Developer/mpd/conf
  ```
- WireGuard.app's tunnel list is **emptied** of any prior mpd
  tunnels (mpd-desktop's old tunnel, in particular). Open WG.app
  and delete any tunnel whose name starts with `mpd-`.
- The System Keychain has any prior `mpd.test local development CA`
  removed via Keychain Access (or the `security delete-certificate`
  recipe from today's bash `uninstall.sh`).

With that clean slate, no detection logic is needed for old-layout
state, no migration code is written, and no two-identities-coexist
handling matters. Phase A begins on a host that has never seen mpd.

## Priority and rollout

**`mpd-prl` (mpd-machine via Parallels) is the only mandatory target
of this proposal.** Everything below is specified primarily for that
binary's first implementation.

mpd-desktop is **fully uninstalled** before Phase A begins (per
the "Assumed starting state" section). During the mpd-prl rollout
it simply isn't present on the host; no state, no Podman Desktop
machine, no `~/.mpd/`, no `~/.mpd-desktop/` (it doesn't exist
yet), nothing in `conf/` from a prior install.

The "Implications for mpd-desktop" and "Refactor needed in
mpd-desktop" sections describe the *later* alignment pass. When
that lands, mpd-desktop gets re-set-up on a host that already has
`conf/wireguard/mac.{private,public}` from mpd-prl; both products
converge on one Mac identity automatically. No migration code, no
ceremony — see "Migration" below.

## Non-goals

- Migration from existing installs. No mpd-prl deployments exist yet
  to migrate. mpd-desktop's directory restructure (moving its
  host-side meta out of `~/.mpd/` into `~/.mpd-desktop/`) is a
  one-time breaking change that lands with this work — no
  back-compat shims.
- Linux/Windows host equivalents. The state-dir model has plausible
  analogues there but they're out of scope for this proposal.
- Cross-Mac sync of the WG identity. Each Mac is its own
  `mac.private`; multi-Mac users have multiple peers in their VM
  configs.
- WireGuard config exchange protocol (peer discovery, etc.). All
  configs are written by Swift on the Mac and pushed to the Linux
  side — no negotiation, no shared secret over the wire beyond what
  SCP already gives us.

## Part 1 — The three-directory state model

### One sentence per owner

- **`~/Developer/mpd/conf/`** — identity. **The user owns it**;
  persistent across every uninstall.
- **`~/.mpd-<product>/`** — product orchestrator's bookkeeping.
  **The product owns it**; removed by `<product> --uninstall`.
- **`~/.mpd/`** — runtime state. **The runtime owns it**; lives
  wherever the runtime physically runs (Mac filesystem for
  mpd-desktop; inside the VM for mpd-machine). Removed by the
  product's `--uninstall` that runs on the same filesystem.

### Concrete directory layout (macOS host, both products coexisting)

```
~/Developer/mpd/                  # source + persistent identity
├── bin/                          # built binaries
├── conf/                         ← identity (user owns; survives uninstall)
│   ├── caroot/
│   │   ├── rootCA.pem
│   │   └── rootCA-key.pem
│   ├── wireguard/                ← see Part 2
│   │   ├── mac.private
│   │   ├── mac.public
│   │   ├── desktop/
│   │   │   ├── private
│   │   │   ├── public
│   │   │   ├── server.conf
│   │   │   └── client.conf       # imported into WG.app as "mpd-desktop"
│   │   └── machine/
│   │       └── <octet>/
│   │           ├── private
│   │           ├── public
│   │           ├── server.conf
│   │           └── client.conf   # imported into WG.app as "mpd-machine-<octet>"
│   ├── service/
│   ├── temp/
│   └── platform.env

~/.mpd-machine/                   ← mpd-prl bookkeeping (removed by `mpd-prl uninstall`)
├── current.env                   # MPD_VM_UUID pointer
└── <uuid>/
    └── env                       # MPD_VM_UUID, NAME, IP, USER
                                  # (future: per-VM logs, cache)

~/.mpd-desktop/                   ← mpd-desktop bookkeeping (new — see "Refactor" below)
├── current.env                   # MPD_MACHINE_NAME pointer
└── <machinename>/
    └── env                       # MPD_MACHINE_NAME, podman state snapshot
                                  # (future: per-machine data)

~/.mpd/                           ← mpd-desktop runtime state (Mac filesystem)
├── machines/<name>/
│   ├── runtime cache
│   └── sidecar reconciliation
└── (other runtime state)
```

And inside any mpd-machine VM:

```
~/.mpd/                           ← mpd-machine runtime state (VM filesystem)
├── machines/mpd-machine/
│   └── (same shape as mpd-desktop's ~/.mpd/)
└── (other runtime state)
```

The two `~/.mpd/` directories never collide because they're on
different filesystems.

### Lifecycle rules

| Action | What it touches |
|---|---|
| `<product> --setup` | Reads/writes `conf/` (idempotent). Creates `~/.mpd-<product>/` and `~/.mpd/` if missing. |
| `<product> --uninstall` | Removes `~/.mpd-<product>/` and `~/.mpd/` (the latter only on whichever filesystem the runtime ran on). **Never** touches `conf/`. |
| `rm -rf ~/Developer/mpd/conf/` | User's manual nuclear option. Resets identity completely; next `--setup` regenerates. |
| Recreate a VM at the same `<octet>` | New env file under `~/.mpd-machine/<uuid>/`. Reuses `conf/wireguard/machine/<octet>/` keys — WG.app tunnel still works. |
| Recreate Podman Desktop machine | New env file under `~/.mpd-desktop/<machinename>/`. Reuses `conf/wireguard/desktop/` keys. |

### Refactor needed in mpd-desktop (deferred — see "Priority and rollout")

This section describes the eventual cleanup that aligns mpd-desktop
with the three-directory model. **Not part of the initial mpd-prl
rollout.** mpd-desktop continues to use its current mixed
`~/.mpd/` layout until someone has time to do the alignment pass.

Today mpd-desktop's host-side meta (which Podman machine is active,
machine-name snapshot) lives mixed into `~/.mpd/state` and
`~/.mpd/machines/<name>/`. When the alignment pass happens, that
meta moves into the new `~/.mpd-desktop/`:

| Today | After alignment |
|---|---|
| `~/.mpd/state` (current machine name + meta) | `~/.mpd-desktop/current.env` + `~/.mpd-desktop/<machinename>/env` |
| `~/.mpd/machines/<name>/` (runtime + reconciliation cache, mixed) | `~/.mpd/machines/<name>/` keeps runtime cache only; host meta extracted to `~/.mpd-desktop/<machinename>/` |

Concretely: `Mpd.Core.State.activeMachine()` (and any host-meta
readers) would read from `~/.mpd-desktop/current.env`; runtime-cache
code keeps reading from `~/.mpd/`. Inside an mpd-machine VM the same
`Mpd.Core.State.activeMachine()` reads from a per-VM analogue (or
just stays pinned to "mpd-machine" as today — the VM has no host-meta
distinction to make).

## Part 2 — WireGuard architecture

### Tunnel addressing

```
Mac (WireGuard.app)               Linux end (mpd-desktop's WG container OR mpd-machine's VM)
────────────────────              ────────────────────────────────────────────────────────
utun (10.164.0.1)        ←──UDP─→  wg0  (10.164.0.2)
                                    │
                                    │ AllowedIPs route forward to:
                                    ▼
                              containers @ 10.163.0.x
                              dnsmasq @ 10.163.0.3
```

**`10.164.0.0/30`** is the WG point-to-point tunnel subnet, same as
mpd-desktop uses today. Reusing it for mpd-prl gives:

- A single tunnel-end address scheme across both products. WireGuard.app
  shows all peers with consistent tunnel addressing.
- Free mutual exclusion: both tunnels claim `10.164.0.1` on the Mac
  end, so WireGuard.app deactivates the previous when you activate
  the next. Matches the "only one active mpd VM/machine at a time"
  constraint we'd want anyway.

**DNS** via the tunnel: each `client.conf` includes
`DNS = 10.163.0.3, mpd.test` (and `MatchDomains = mpd.test` if you
want to scope strictly to that suffix rather than route all DNS
through the tunnel). When the tunnel is up, `*.mpd.test` resolves
via dnsmasq through the tunnel. **No more `/etc/resolver/mpd.test`
file** — WireGuard.app owns DNS scope.

**AllowedIPs** on the Mac peer: `10.164.0.0/30, 10.163.0.0/24`. The
container subnet is reachable via the tunnel; the host route to
`10.163.0.0/24` is now owned by the tunnel too. **No more
`sudo route add` step** — WireGuard.app owns the route.

### Key management

All keypairs generated in Swift on the Mac via
`CryptoKit.Curve25519.KeyAgreement.PrivateKey` (Curve25519 is exactly
what WireGuard uses for static keys). One Swift module owns it:

```swift
// MpdCore.WireGuard
struct Keypair {
    let privateKey: String     // base64-encoded
    let publicKey: String      // base64-encoded

    static func generate() -> Keypair
    static func load(from dir: URL) throws -> Keypair?    // nil if missing
    func save(to dir: URL) throws                          // writes private+public files mode 0600/0644
}

enum Role {
    case desktop
    case machine(octet: Int)
}

struct Peer {
    let role: Role
    let mac: Keypair                   // shared identity across all peers
    let linux: Keypair                 // per-peer
    let endpoint: String               // host:port of the Linux side
    let serverTunnelIP: String         // 10.164.0.2
    let clientTunnelIP: String         // 10.164.0.1
    let allowedIPsFromMac: [String]    // [10.164.0.0/30, 10.163.0.0/24]
    let dns: String                    // 10.163.0.3
    let dnsMatchDomains: [String]      // [mpd.test]

    /// Loads existing keys + endpoint config from `~/Developer/mpd/conf/wireguard/`,
    /// generating fresh on the first call. Idempotent.
    static func loadOrGenerate(role: Role, endpoint: String) throws -> Peer

    func renderServerConf() -> String     // → /etc/wireguard/mpd0.conf inside the Linux side
    func renderClientConf() -> String     // → imported into WireGuard.app on the Mac

    /// Tunnel address of the corresponding `Mpd.Service.Dnsmasq.ip` (10.163.0.3)
    /// is the same across both products — the constant lives in `MpdCore`.
}
```

`mac.{private,public}` is generated **once** the first time any
product calls `Peer.loadOrGenerate(...)`. Persisted at
`~/Developer/mpd/conf/wireguard/mac.{private,public}`. Every subsequent
call (whether for desktop or for a new mpd-machine VM) reuses it.

`<role>/{private,public,server.conf,client.conf}` is generated on
first call per role. Persisted at
`~/Developer/mpd/conf/wireguard/<role>/`. Every subsequent call reuses.

### Where private keys live (and don't)

- **`mac.private`** lives at `~/Developer/mpd/conf/wireguard/mac.private`
  on the Mac. Mode `0600`. Never transits anywhere.
- **`<role>/private`** lives at
  `~/Developer/mpd/conf/wireguard/<role>/private` on the Mac. Mode
  `0600`. Is pushed once into the Linux side during initial
  provisioning (via `scp` into VM, or `podman cp` / bind-mount into
  the WG container). Both copies of the file persist.

The Linux-side private key does briefly transit the Mac orchestrator
in memory during generation, and on the wire (encrypted over SSH /
within Podman Desktop's local socket). That's a small concession
relative to the convenience win: the same key can be re-pushed into
a recreated VM/container without regenerating, so WireGuard.app
configs stay valid across rebuilds. The security trade-off is
explicitly fine — see "Threat model" below.

### Daily user flow (steady state)

1. Host reboots. Parallels auto-resumes the active mpd-machine VM
   (Parallels' default), OR mpd-desktop's Podman Desktop machine
   auto-starts on user login if configured.
2. User opens WireGuard.app, toggles the active tunnel on.
   **No password prompt** (WireGuard.app's system extension was
   authorized at install time).
3. `https://mpd.test/` resolves. SSH to the VM works. `mpd` (in-VM
   or native) is reachable.

That's it. **Zero sudo in the daily loop.** All sudo is at setup
time.

### Recreation flow

User deletes mpd VM `mpd-machine-159` in Parallels, decides to recreate
it from the template:

1. `mpd-prl setup`, picks octet `159` again.
2. Swift sees `~/Developer/mpd/conf/wireguard/machine/159/` exists →
   reuses the existing keypair + configs.
3. Clones template, provisions, **scp's the existing `server.conf`**
   into the new VM at `/etc/wireguard/mpd0.conf`, enables
   `wg-quick@mpd0`.
4. **WireGuard.app's existing `mpd-machine-159` tunnel is untouched.**
   No re-import needed. The new VM has the same WG identity as the
   one that was deleted.

This is the whole point of persistent identity in `conf/`. The VM is
disposable; the WG keys are not.

### Switching between VMs

User has two mpd-machine VMs (octets `155` and `156`) cloned from the
template:

1. WireGuard.app shows `mpd-machine-155` and `mpd-machine-156` as two
   tunnels.
2. Both claim Mac end `10.164.0.1`, so only one can be active.
3. Toggling between them is the entire UX — no setup-script invocation,
   no IP collision handling, no host-state mutation.

### Initial setup (the only place sudo appears)

`mpd-prl setup` on a fresh Mac:

1. **One sudo prompt for the CA trust step** (`sudo security
   add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain
   <caroot/rootCA.pem>`). One time, never again.
2. **One-time admin auth for WireGuard.app's system extension**
   (macOS native flow, happens at first install of WireGuard.app
   when the user installed it from the App Store). Not mpd's problem.

After that — including all VM clones, switches, recreations — zero
sudo. The daily-no-sudo property holds for all subsequent activity.

### Implications for mpd-prl

References [`host-binary-parallels.md`](host-binary-parallels.md).
The host-side steps shrink:

| `mpd-prl setup` step | Today's proposal | After this proposal |
|---|---|---|
| `sudo route add -net 10.163.0.0/24 <vm-ip>` | required | **gone** (WG handles it) |
| `sudo tee /etc/resolver/mpd.test` | required | **gone** (WG handles it) |
| `sudo security add-trusted-cert` (CA) | required (one-time) | unchanged |
| Push `server.conf` to VM, enable `wg-quick@mpd0` | n/a | **new** (one-time per VM lifecycle) |
| Import `client.conf` into WireGuard.app | n/a | **new** (one-time per VM lifecycle) |

The `mpd-prl doctor` verb simplifies: instead of "check the host
route + resolver + CA," it becomes "check the WG tunnel is up +
reachable + sees `mpd.test`." Multi-VM detection (warn if more than
one running) still has value because IP collisions matter; the
tunnel-mutual-exclusion property doesn't save you from two VMs both
trying to claim `10.211.55.155`.

### Implications for mpd-desktop (later)

mpd-desktop already uses WireGuard. When the future alignment pass
happens (see "Priority and rollout"), it cleans up two things:

- **WG container becomes thinner.** Its current first-run logic
  (`wg genkey` inside the container, then exposed somehow) goes
  away. The container just runs `wg-quick@mpd0` with a config
  bind-mounted in from the Mac side.
- **WG keypair generation moves out of the container** into Swift
  (`MpdCore.WireGuard.Peer.loadOrGenerate`). Shared code with
  mpd-prl. No more "find the WG container's pubkey" SSH/exec dance.

Net effect on mpd-desktop after alignment: same daily UX, less
per-product code, key reuse with mpd-prl. **None of this work is
gating mpd-prl's first ship.**

### Implications for `MpdCore`

The library target adds:

```
MpdCore  (Swift module)
└── Mpd.Core
    ├── Platform        # (existing)
    ├── State           # (existing)
    ├── Assets          # (existing)
    ├── Identity        # (existing)
    ├── Certificate     # CA generation (existing, promoted from Mpd.Environment.Certificate)
    └── WireGuard       # NEW: Keypair, Peer, loadOrGenerate, conf rendering, tunnel detection
```

`Mpd.Core.WireGuard.Peer.loadOrGenerate(role: .machine(octet: 159), …)`
is the entry point both products use. Same function, two callers,
same persistent layout in `conf/wireguard/`.

The tunnel-up detection logic currently in
`mpd/Environment/Desktop/DesktopIntegration.swift:109` (the
`utun with 10.164.0.1 in ifconfig` predicate) moves into
`Mpd.Core.WireGuard.isTunnelActive()`. Both products consume it.

## Threat model

The model is "the Mac is the trust origin; the Linux side is
disposable":

| Asset | Lives on | Compromise impact |
|---|---|---|
| mpd CA private key | Mac (`conf/caroot/`) | Can sign arbitrary `*.mpd.test` certs (name-constrained; limited blast radius) |
| `mac.private` (WG) | Mac (`conf/wireguard/`) | Can impersonate the Mac to any peer that trusts it |
| `<role>/private` (WG) | Mac (`conf/wireguard/`) + Linux side | Can impersonate that peer to the Mac. Briefly transits Mac in memory + over SSH/podman during initial provisioning |
| SSH private key | Mac (`~/.ssh/`) | Root in any mpd-machine VM (dev user has passwordless sudo) |

A Mac compromise gives you everything. The VM-side WG private key
sitting on the Mac doesn't enlarge that — the SSH key already
implies VM root. The persistence-on-Mac decision is the right
trade-off for the convenience win.

A *VM* compromise (e.g. via a malicious project) does not climb back
to the Mac: the Mac-side WG private key is not on the VM, the CA
private key is not on the VM (only the cert is), and SSH is
one-way (VM doesn't have keys to access the Mac).

The Linux-side WG private key sitting in
`~/Developer/mpd/conf/wireguard/<role>/private` is in the same trust
class as the CA private key. Both are at mode `0600` and live in the
same protected dir; standard macOS filesystem permissions apply.

## Migration

**No migration code is written.** The "Assumed starting state"
section above is what makes that possible: the macOS host begins
empty and accumulates state forward from there. There's never an
"old layout" to detect or convert.

- **Phase A + B (mpd-prl ships):** `mpd-prl setup` generates the CA
  + `mac.{private,public}` + per-VM keypair fresh in `conf/` and
  `~/.mpd-machine/`. mpd-desktop is uninstalled on the host; nothing
  about it exists to migrate.
- **Phase C (mpd-desktop alignment, later):** `mpd --setup` runs
  on a host that already has `conf/wireguard/mac.{private,public}`
  populated by mpd-prl. `Mpd.Core.WireGuard.Peer.loadOrGenerate(role: .desktop, …)`
  **reuses the existing `mac.private`** — both products converge on
  one Mac identity automatically, no orchestration needed. The
  desktop role's own `private`/`public` keypair gets generated on
  first call. New `client.conf` for the desktop tunnel is handed
  to WireGuard.app. No conf-wiping ceremony, no re-provisioning of
  existing mpd-prl VMs (the CA didn't change, mac identity didn't
  change). It's just "mpd-desktop gets set up alongside the
  already-running mpd-prl."

The cleanliness of this story is the whole reason the starting-state
assumption is worth enforcing. Any "what if X already exists" branch
is replaced with "starting state assumes X doesn't exist." No
detection logic, no two-identities transitions, no operational
checklist beyond the standard product setup flows.

## Open questions

- **Should `mac.private` be backed up?** It's the user's Mac
  identity across all mpd peers. Losing it means every WG.app
  tunnel needs re-generating + re-importing (manageable but
  annoying). Worth a `mpd-prl export-identity` / `import-identity`
  flow to bundle `conf/wireguard/mac.{private,public}` for off-Mac
  backup? Probably defer until someone wants it. Time Machine
  catches `conf/` by default if the user has it enabled.
- **Should `<role>/private` be regeneratable on demand?** A
  hypothetical `mpd-prl rotate-wireguard <octet>` verb would
  generate a new Linux-side keypair, push it to the VM, rewrite
  `client.conf`, prompt the user to re-import. Not urgent.
- **Inside the mpd-machine VM, does the in-VM `mpd --setup` need
  any awareness of the host's WireGuard?** Probably not — the VM
  doesn't care about the tunnel; it just hosts `wg-quick@mpd0` as a
  systemd service that's enabled by the host orchestrator's provisioning
  step. The `mpd-prl setup` orchestrator handles the integration.
- **mpd-desktop's host-meta migration carries some risk** because
  the existing `~/.mpd/state` format is parsed by code that's about
  to move. Worth a small focused test pass against a populated
  `~/.mpd/` before this lands.

## Sequencing

The implementation order anchored on the user-facing priority
(mpd-prl first, mpd-desktop alignment later):

1. **`MpdCore.WireGuard` library code** (Swift Curve25519 keypair
   generation, `Peer.loadOrGenerate`, config rendering, tunnel-up
   detection). No host-state changes, no mpd-desktop touching.
   Self-contained Swift addition with unit tests.
2. **`~/.mpd-machine/<uuid>/` subdir layout in mpd-prl's spec.**
   Folds into [`host-binary-parallels.md`](host-binary-parallels.md)'s
   state-files section — small refinement of today's flat
   `<uuid>.env` shape into `<uuid>/env`. No data migration (mpd-prl
   doesn't exist yet).
3. **mpd-prl ships with WG-based networking from day one.** Per
   [`host-binary-parallels.md`](host-binary-parallels.md) updated
   to drop the `sudo route add` + `/etc/resolver/` steps and add
   the WG provisioning step instead.
4. **Optional, much later: mpd-desktop alignment.** The
   `~/.mpd-desktop/` directory rename, the WG container thin-out,
   the `client.conf` re-import for existing users. Lands when
   convenient; doesn't gate anything.

Net: steps 1–3 are the "mpd-prl first-class" path. Step 4 is the
cleanup that the existence of mpd-prl makes worthwhile, but happens
on its own timeline.
