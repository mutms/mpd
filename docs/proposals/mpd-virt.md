# Proposal: `mpd-virt` — host-side binary for driving mpd-machine VMs

A new Swift binary that replaces the bash scripts under `setup/macos/lib/`,
`setup/linux/lib/`, and `setup/windows/lib/`. **One binary name —
`mpd-virt` — across every platform**, with the backend (Parallels /
libvirt-KVM / Hyper-V) selected at build time via per-platform Swift
target conditioning.

The companion proposal
[`macos-host-state-and-wireguard.md`](macos-host-state-and-wireguard.md)
covers the architectural choices `mpd-virt` builds on (three-directory
state model, WireGuard-based networking, persistent identity in
`~/Developer/mpd/conf/`). Read that first; this document specifies the
binary itself.

## Goals

1. **One binary name everywhere.** `mpd-virt` on macOS (Parallels),
   `mpd-virt` on Linux (KVM), `mpd-virt` in WSL (Hyper-V). Documentation
   says one thing; users invoke one thing.
2. **One Swift source tree.** Per-backend code lives under
   `Mpd.Virt.Parallels` / `Mpd.Virt.KVM` / `Mpd.Virt.HyperV`, conditioned
   by `#if os(...)` so each compiled binary contains only the relevant
   backend. No runtime backend detection — too confusing.
3. **Eliminate the bash twin** of `Mpd.Environment.Certificate.generateCA`
   (today's `generate_mpd_ca` in `setup/macos/lib/common.sh` and its
   siblings in `setup/linux/`/`setup/windows/`). One Swift implementation,
   used by every backend.
4. **ArgumentParser-driven tab completion** for verbs and dynamic VM
   names, same shape `mpd` already uses for project names.
5. **Number-to-clipboard sudo-recipe UX** — numbered list of required
   `sudo` commands, digit copies the line via the platform's clipboard
   tool.

## Non-goals

- Replacing the in-VM `mpd` binary. Linux Swift build of `mpd` is
  unchanged.
- A `.app` bundle / Dock icon. CLI binary only. Native macOS UI is a
  follow-up proposal if you ever want it.
- Distribution outside GitHub releases + `make install`. No Homebrew
  formula, no notarized installer (defer until non-dev users ask).
- Cross-platform autodetection between backends. Each compiled binary
  has exactly one backend.

## Priority

**macOS + Parallels is the only mandatory target.** Linux/KVM and
Hyper-V (WSL-resident) exist in the spec so a contributor can build
them, but they're not gating anything. The user pursuing this proposal
runs Parallels Desktop Pro on macOS as their daily driver; that's
where `mpd-virt` has to feel first-class.

Windows-via-Hyper-V is explicitly the lowest-priority backend: there
are zero current Windows users, and the design (WSL-resident Linux
Swift binary, `powershell.exe` interop) is documented mostly so an
interested implementer doesn't have to re-derive it.

## VM identity model: octet as the canonical key

`mpd-virt` uses the **last IP octet** as the canonical identifier for
each mpd-machine VM throughout its storage layout:

- VM name in Parallels: `mpd-machine-<octet>`
- Static IP on Parallels Shared: `10.211.55.<octet>`
- Host state dir: `~/.mpd-virt/<octet>/`
- WG configs: `~/Developer/mpd/conf/wireguard/machine/<octet>/`
- WG.app tunnel name: `mpd-machine-<octet>`
- SSH config aliases: `mpd-machine-<octet>` and
  `mpd-machine-<octet>-<runtime>`
- `current.env`: `MPD_VM_OCTET=<octet>`

One number, encoded everywhere, predictable and tab-completable.

**Rule: do not rename mpd VMs in Parallels.** The whole storage
layout assumes the Parallels VM name stays `mpd-machine-<octet>` for
its lifetime. Renaming in the Parallels GUI is explicitly
unsupported. (To "rename" effectively: `mpd-virt clone <src>
<new-octet>` to a new octet, then `mpd-virt uninstall <old-octet>`
to retire the original.)

**UUID is kept as diagnostic metadata, not as an index.** The
Parallels-issued UUID for each VM is stored in
`~/.mpd-virt/<octet>/env` (as a `MPD_VM_UUID=...` line) so that
`mpd-virt doctor` can verify "the VM currently named
`mpd-machine-<octet>` in Parallels is still the one I provisioned"
when investigating weirdness. But the day-to-day lookup path is
**name → octet → IP**; UUID never gets touched in normal operation.
This keeps `prlctl` invocations human-readable (`prlctl start
mpd-machine-222`, not `prlctl start
{abc12345-aaaa-bbbb-cccc-...}`) and makes log output much easier to
follow.

If `mpd-virt doctor` finds the UUID drift (someone renamed despite
the rule, or recreated a VM at the same octet from scratch), it
surfaces an advisory but doesn't refuse to operate — the user
decides whether to update the stored UUID or restore the name.

## The binary

`mpd-virt` is invoked from the user's host shell. On macOS it lives at
`/usr/local/bin/mpd-virt` (or `~/Developer/mpd/bin/mpd-virt` on PATH).
On Linux it's the same path. In WSL Debian it's the same path inside
the WSL filesystem.

### User-facing verb surface

| Verb | Args | What it does |
|---|---|---|
| `setup` | — | Interactive new-VM creation or switch-to-existing. Octet-keyed picker; new-VM path prompts for octet/user/memory/disk and clones the platform's template. |
| `doctor` | — | List all tracked VMs + states + "configured" tag. If exactly one is running, verify/re-apply host networking. Multi-runner warning when >1 running (static-IP collision footgun). |
| `uninstall` | `[--yes]` | Tear down host networking + state files. Per-VM y/N prompt (or `--yes` for non-interactive). Respects the CA-preservation rule (skip keychain removal if `~/Developer/mpd/conf/caroot/` still exists). |
| `list` | `[--json]` | Print tracked VMs as a table. JSON variant for scripting. |
| `start` | `<vm>` | Boot the VM. If a different mpd-virt VM is running, suspend it first (one-running-at-a-time). Re-apply host networking to the new VM's IP. Updates `current.env`. Idempotent. |
| `stop` | `<vm>` | Suspend the VM. With `--kill`, hard-stop. |
| `ssh` | `<vm> [-- cmd …]` | SSH into the VM. With trailing args, run a one-shot command. |
| `clone` | `<src-vm> <new-octet>` | Backend-native clone of an existing VM into a new `mpd-machine-<new-octet>` name. Writes `~/.mpd-virt/<new-octet>/env` (with the clone's new UUID recorded as diagnostic metadata). The clone is renamed in Parallels to match the new octet; the in-guest NetworkManager keyfile is rewritten to the new static IP before first boot. |

The `<vm>` placeholder accepts either a friendly VM name or a UUID.
Completion resolves to the *current* name for each tracked UUID,
queried from the backend at completion-script-eval time so a rename in
the backend's GUI shows up immediately.

### Argument & completion contract

Standard Swift ArgumentParser:

```swift
struct Start: ParsableCommand {
    @Argument(
        help: "VM friendly name or UUID.",
        completion: .custom { _ in trackedVMNames() }
    ) var vm: String
}
```

`trackedVMNames()` walks `~/.mpd-virt/*.env`, queries the backend per
UUID for the current friendly name, returns the list. Same approach
`mpd start <project>` uses today.

Completion shims (zsh, bash) ship via `mpd-virt --generate-completion-script
zsh|bash`, installed by `make install` into the standard locations.

### Sudo-recipe UX

Centralized in `Mpd.Virt.Host.SudoRecipe` inside the `mpd-virt` target.
Behaviour (same on every backend that uses `sudo`):

1. Print a numbered list of the privileged commands, one per line.
2. Read a single character (no Enter needed):
   - `1`–`9` → copy that command to the platform clipboard
     (`pbcopy` on macOS, `xclip`/`wl-copy` on Linux, `clip.exe` on
     WSL), print "copied — paste in another terminal, then press
     Enter when done." Re-prompt.
   - `a` → run all commands via `sudo -v` + per-command `Process()`
     invocations (or platform equivalent — see HyperV section for
     UAC).
   - `q` → abort.
3. After each manual copy-and-run, re-detect what's still needed. If
   the user fixed everything by hand, exit without prompting.

`ClipboardWriter` protocol with per-platform implementations
(`MacOSPasteboard`, `LinuxClipboard`, `WSLClipboard`) keeps the
recipe printer itself backend-agnostic.

### SSH config block

`mpd-virt setup` writes a managed block to `~/.ssh/config` that gives
the user predictable Host aliases for the VM and each of its runtime
containers, all reachable from the Mac with no IP memorization and no
WireGuard dependency.

The runtime set is **fixed and known** — today's mpd ships three
runtimes (`php`, `node`, `util`). Their hostnames inside the VM are
stable (`<runtime>.runtime.mpd.test`, resolved by the in-VM
dnsmasq). So the SSH block is a **static template** that mpd-virt
writes once per VM at setup time, never re-synced. SSH to a runtime
that hasn't been started yet returns "Connection refused" — fine,
the user starts the runtime inside the VM and retries.

Block shape (one per VM, written between the standard managed-block
markers — same approach the existing bash uses):

```
# >>> mpd-machine (managed by mpd-virt) >>>
Host mpd-machine-<octet>
    HostName <vm-static-ip>
    User <dev-user>
    StrictHostKeyChecking no

Host mpd-machine-<octet>-php
    HostName php.runtime.mpd.test
    User user
    ProxyJump mpd-machine-<octet>
    StrictHostKeyChecking no

Host mpd-machine-<octet>-node
    HostName node.runtime.mpd.test
    User user
    ProxyJump mpd-machine-<octet>
    StrictHostKeyChecking no

Host mpd-machine-<octet>-util
    HostName util.runtime.mpd.test
    User user
    ProxyJump mpd-machine-<octet>
    StrictHostKeyChecking no
# <<< mpd-machine <<<
```

User-visible UX:

- `ssh mpd-machine-222` — direct SSH to the VM (uses Parallels Shared
  IP `10.211.55.222`, no tunnel needed).
- `ssh mpd-machine-222-php` — SSH into the php runtime, automatically
  ProxyJumping through the VM. `<runtime>.runtime.mpd.test` resolves
  via the VM's dnsmasq during the inner hop.
- `ssh mpd-machine-222-node`, `ssh mpd-machine-222-util` — same
  pattern.
- PHPStorm Gateway / VSCode Remote-SSH point at these Host aliases
  directly; the ProxyJump is transparent.
- `scp mpd-machine-222-php:/srv/projects/foo/bar.txt .` works.

**Independent of WireGuard, but not exclusive:**

The SSH ProxyJump path uses the VM's Parallels Shared static IP
(reachable from the Mac without any tunnel) and the in-VM dnsmasq
for the inner hop. WireGuard isn't in that path — but WG is also
still running with full container-subnet routing
(`AllowedIPs = 10.164.0.0/30, 10.163.0.0/24`), so there's also an
IP-level path to every container in `10.163.0.0/24` via the tunnel
if anyone wants it (direct-by-IP SSH, browser HTTPS, ad-hoc TCP).
Two convergent paths, both supported, no scope-narrowing on WG.

- WG tunnel off + VM running → `ssh mpd-machine-222` and
  `ssh mpd-machine-222-php` both work (via ProxyJump + Parallels
  Shared). Browser to `https://*.mpd.test/` does not.
- WG tunnel on + VM running → both SSH-via-ProxyJump and IP-level
  paths (HTTPS browser, direct-by-IP container access) are
  available simultaneously; user picks whichever is convenient.
- Easier debugging: SSH-config-block failures point at Parallels VM
  state; browser HTTPS / direct-IP failures point at WireGuard
  state. Two independent diagnostics.

**Block lifecycle:**

- Written by `mpd-virt setup` (full block, all four entries).
- Re-asserted by `mpd-virt doctor` (idempotent — same content unless
  the VM IP / dev user changed).
- Removed by `mpd-virt uninstall` (strips just the marked block, like
  today's bash does).
- **Never automatically re-synced** when runtimes are created/destroyed
  inside the VM. The block is static; absent runtimes manifest as
  "Connection refused" on `ssh`, which is a clear enough signal.

**If the fixed runtime list ever grows** (e.g. mpd adds a `python`
runtime): the user re-runs `mpd-virt setup` (or `mpd-virt doctor`)
after upgrading mpd; the block gets the new entry. Annual-rare event;
no auto-detection needed.

### In-VM hostname alignment (dependency on the in-VM `mpd` binary)

For the SSH aliases to feel natural end-to-end, the **runtime container
hostnames inside the VM should match the SSH alias names**. Today the
in-VM mpd (the existing Linux Swift binary) uses
`Mpd.Environment.Machine.MachineActionSetup.deriveInstanceSuffix()` to
name runtime containers like `mpd-runtime-<runtime>-<suffix>` (e.g.
`mpd-runtime-php-222`). After this proposal lands, the user typing
`ssh mpd-machine-222-php` would land inside a container whose
internal hostname is `mpd-runtime-php-222` — same VM, different word
order, mildly confusing in a terminal with several tabs open.

**Required alignment**: change the in-VM runtime-naming convention from
`mpd-runtime-<runtime>-<suffix>` to `mpd-machine-<octet>-<runtime>`,
matching the SSH alias exactly. Concretely:

- Same prefix as the VM (`mpd-machine-`) rather than the
  runtime-specific `mpd-runtime-` — emphasizes that the runtime is
  *in* a specific mpd-machine VM, not a free-standing thing.
- Octet before runtime — matches IP encoding and SSH-config word
  order.
- DNS names inside the VM (`php.runtime.mpd.test` and friends) stay
  unchanged. They're the external addressing identity; the container
  hostname is only the shell-prompt identity.

**Where the change lives**: in the existing `mpd` binary (in-VM Linux
Swift), specifically wherever podman is invoked to create runtime
containers with `--hostname <…>`. The function that builds that
hostname template is the one to update — replacing the
`deriveInstanceSuffix`-based shape with an `mpd-machine-<octet>-<runtime>`
shape. `<octet>` comes from the VM's own hostname (the VM is named
`mpd-machine-<octet>`, so reading `/etc/hostname` and splitting on the
last `-` gives the octet).

**Sequencing**: this in-VM change is independent of `mpd-virt` itself,
but they're a matched pair — landing one without the other leaves the
asymmetry in place. The recommendation is to land the in-VM
hostname-template change first (or at least together with mpd-virt's
first ship), so that day-one users of `mpd-virt setup`-installed SSH
aliases get the consistent in-container shell prompt.

This whole subsection describes work *outside* mpd-virt's own scope,
but recording the dependency here keeps the consistency requirement
visible during implementation.

## Build & release

### Two Makefiles

**`Makefile`** (existing, untouched, macOS-focused — Apple Silicon
arm64, Xcode coexistence):

```makefile
# macOS — Apple Silicon, copies (empirically required for reliability)
mpd:
	swift build -c release --product mpd

mpd-virt:
	swift build -c release --product mpd-virt

install: mpd mpd-virt
	mkdir -p bin
	install "$(CURDIR)/.build/release/mpd"      "bin/mpd"
	install "$(CURDIR)/.build/release/mpd-virt" "bin/mpd-virt"
```

Uses `install` (BSD/coreutils, copies with 755) — same pattern the
existing Makefile already uses for `mpd`. **No symlinks on macOS** —
prior testing showed copies are empirically required for reliability.

Xcode build process stays in sync automatically: `Package.swift` is
the source of truth, both Xcode and `swift build` produce the same
binary at the same `.build/release/<product>` path. Adding `mpd-virt`
as a new `executableTarget` means Xcode picks it up as a new scheme
on next project open; no Xcode-side configuration needed.

**`Makefile.linux`** (new — handles all the Linux multi-arch /
multi-distro / WSL-vs-native complexity):

```makefile
# Linux Swift builds — symlinks freely; no Xcode equivalent to worry about.
.DEFAULT_GOAL := all
.PHONY: all mpd mpd-virt install clean

ARCH := $(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
REL  := release/linux/$(ARCH)

all: mpd mpd-virt

mpd:
	swift build -c release --static-swift-stdlib --product mpd
	@mkdir -p "$(REL)"
	@ln -sf "$(CURDIR)/.build/release/mpd" "$(REL)/mpd"

mpd-virt:
	swift build -c release --static-swift-stdlib --product mpd-virt
	@mkdir -p "$(REL)"
	@ln -sf "$(CURDIR)/.build/release/mpd-virt" "$(REL)/mpd-virt"

install: all
	@mkdir -p bin
	@ln -sf "$(CURDIR)/.build/release/mpd"      bin/mpd
	@ln -sf "$(CURDIR)/.build/release/mpd-virt" bin/mpd-virt

clean:
	swift package clean
```

Invoked as `make -f Makefile.linux <target>`. Linux is symlink-happy
because there's no empirical reliability issue and the rebuild → PATH
loop is tighter that way.

### Asymmetry rule

| Platform | Bin install | Reason |
|---|---|---|
| macOS | `install` (copy) | Earlier testing showed copies are empirically required for reliability + matches existing Xcode setup. |
| Linux | `ln -sf` (symlink) | Tighter rebuild loop, immediate PATH visibility, no copy step to forget. Empirically works fine. |

This is **the** design rule. No proposing to "normalize" it.

### Release tree

Build artifacts go to `release/<os>/<arch>/`:

```
release/
├── macos/arm64/
│   ├── mpd          # copy (existing pattern)
│   └── mpd-virt
└── linux/
    ├── arm64/
    │   ├── mpd      # symlink → .build/release/mpd
    │   └── mpd-virt
    └── amd64/
        ├── mpd
        └── mpd-virt
```

Build on each machine you have, then aggregate the release tree and
`gh release upload vX.Y.Z release/macos/arm64/mpd-virt
release/linux/arm64/mpd-virt ...`. `gh` dereferences symlinks during
upload.

### Isolation property

The two Makefiles are completely separate files. AI iterating in a
sandbox VM (Linux) can only touch `Makefile.linux` and the Linux Swift
sources. The macOS dev environment (existing `Makefile`, Xcode setup,
`bin/mpd`-copies behavior) is physically untouchable from inside the
sandbox. Worst case the Linux symlink dance breaks; the user's
daily-driver Mac is fine.

This is the main reliability story for AI-assisted iteration. Bisecting
also works cleanly — `git bisect` only flips Linux Swift + Linux
Makefile; macOS build remains a fixed point during the bisect.

## Swift namespace layout

```
MpdCore  (library target, macOS + Linux)
└── Mpd.Core
    ├── Platform        # (existing)
    ├── State           # (existing)
    ├── Assets          # (existing)
    ├── Identity        # (existing)
    ├── Certificate     # CA generation (promoted from Mpd.Environment.Certificate)
    └── WireGuard       # Curve25519 keypair gen, Peer.loadOrGenerate, conf rendering, tunnel-up detection

mpd-virt  (executable target, macOS + Linux)
└── Mpd.Virt
    ├── Host                # sudo-recipe printer, clipboard, route abstraction
    │
    ├── Parallels           # #if os(macOS)  — prlctl wrappers
    ├── KVM                 # #if os(Linux)  — virsh wrappers
    └── HyperV              # #if os(Linux)  — PowerShell wrappers (WSL detection at runtime, but
                            #                 conditioning is build-time: both Linux backends compile in,
                            #                 the WSL-vs-native check picks at startup which to dispatch to)
```

The `#if os(macOS)` block guards everything under `Mpd.Virt.Parallels/`;
the `#if os(Linux)` block wraps `Mpd.Virt.KVM/` and `Mpd.Virt.HyperV/`.
Conditional compilation excludes wrong-platform files entirely — the
macOS binary doesn't even *contain* KVM/HyperV code, and vice versa.

The Linux build does contain both KVM and HyperV; the choice between
them is the one acceptable runtime detection (probe
`/proc/sys/kernel/osrelease` for `microsoft` — WSL → HyperV; else
KVM). This is detection between two backends on the SAME compiled
binary, not between backends across binaries. Less confusing than the
unified-runtime-everything proposal that was rejected earlier.

## Per-backend implementation

### Parallels (macOS, primary)

This is the only backend gated as mandatory.

**Hypervisor control via `prlctl`**:

| Verb | prlctl invocation |
|---|---|
| `list` | `prlctl list -a -o uuid,status,name --no-header` (UUID column read for diagnostic stash + drift detection; the canonical lookup key is the name `mpd-machine-<octet>`) |
| `status` | `prlctl status mpd-machine-<octet>` |
| `start` | `prlctl start mpd-machine-<octet>` |
| `stop` (suspend) | `prlctl suspend mpd-machine-<octet>` |
| `stop --kill` | `prlctl stop mpd-machine-<octet> --kill` |
| `clone` | `prlctl clone mpd-machine-<src-octet> --name mpd-machine-<new-octet>` (full clone; linked is a future flag) |
| `delete` | `prlctl delete mpd-machine-<octet>` |

**Networking**: Parallels Shared network (`10.211.55.0/24`), DHCP pinned
to `.1–.99` by the template builder, mpd VMs take static IPs from
`.100+`. Static IP pinned in-guest via NetworkManager keyfile written
during provisioning.

**Template**: user pre-builds a Parallels VM template named
`mpd-machine-template` (Debian Trixie + GNOME + Parallels Tools +
sandbox take-over already run). `mpd-virt setup` clones from this
template.

**Privilege model**: per-command `sudo`. Sudo-recipe printer is the
standard variant — number-to-clipboard via `pbcopy`, "a" runs all
via cached `sudo -v` then per-command `Process()`.

**Host-side networking via WireGuard** (see state-and-wireguard
proposal): no `sudo route add` step, no `/etc/resolver/mpd.test`
write. WireGuard.app owns route + DNS for `*.mpd.test`. Sudo is only
needed once at setup time for the System Keychain CA trust.

### KVM (Linux native, derivative)

Same verbs, libvirt backend. `prlctl` swaps for `virsh`:

| Verb | virsh invocation |
|---|---|
| `list` | `virsh list --all --name` (with `virsh dominfo` per VM to read UUID for diagnostic stash) |
| `status` | `virsh domstate mpd-machine-<octet>` |
| `start` | `virsh start mpd-machine-<octet>` |
| `stop` (suspend) | `virsh suspend mpd-machine-<octet>` (or `managedsave`) |
| `stop --kill` | `virsh destroy mpd-machine-<octet>` |
| `clone` | `virt-clone --original mpd-machine-<src-octet> --name mpd-machine-<new-octet> --auto-clone` |

**Networking**: libvirt default network (`virbr0`, typically
`192.168.122.0/24`). Static IP pinned in-guest via NetworkManager
keyfile, same shape as Parallels.

**Guest IP discovery**: `virsh net-dhcp-leases default` or read
`/var/lib/libvirt/dnsmasq/default.status`.

**Host-side networking**: same WireGuard model as Parallels. Linux
host's WireGuard tooling is `wg-quick` + `systemctl`, not WireGuard.app.

**Sudo recipe**: per-command sudo, Linux clipboard helper auto-detects
`wl-copy` (Wayland) / `xclip` (X11) / falls back to "press 'a' to run
all" if neither present.

### HyperV (Linux in WSL, lowest priority)

Same verbs, Hyper-V backend driven via `powershell.exe` interop from
inside WSL2 Debian. **Not a native Windows binary.** The Linux Swift
build of `mpd-virt`, when running inside WSL, spawns `powershell.exe`
for all Windows-side work (Hyper-V cmdlets, `route.exe -p`,
`Add-DnsClientNrptRule`, `Import-Certificate`, `Set-Clipboard`).

| Verb | PowerShell cmdlet |
|---|---|
| `list` | `Get-VM \| Select-Object Id,Name,State \| ConvertTo-Json` |
| `status` | `(Get-VM -Id <guid>).State` |
| `start` | `Start-VM -Id <guid>` |
| `stop` (suspend) | `Suspend-VM -Id <guid>` |
| `stop --kill` | `Stop-VM -Id <guid> -Force` |
| `clone` | `Export-VM` + `Import-VM -Copy -GenerateNewId -Path … -Rename` |

**Privilege model**: UAC, not per-command sudo. Sudo recipe's "run
all" path spawns `Start-Process -Verb RunAs powershell.exe -ArgumentList
'<combined-script>'` — single UAC prompt for the whole batch.

**Clipboard**: `printf '%s' "<text>" | clip.exe` — one-shot, skips
PowerShell startup latency.

**Why WSL-resident, not native Windows Swift**: same Swift toolchain
as Linux/KVM (`swiftlang` apt package), no Windows code-signing,
inherits the WSL prereq the current `setup/windows/` already requires.
**See discussion in earlier draft** if you want the full rationale;
the short version is: Swift-on-Windows native is more work than it's
worth for a backend nobody currently uses.

## What goes away when this lands

Today's `setup/` tree contains user-runnable bash + PowerShell that
implements what `mpd-virt` will do in Swift:

| Today's path | Becomes |
|---|---|
| `setup/macos/lib/*.sh` (~1500 lines) | Replaced by `Mpd.Virt.Parallels` + `Mpd.Virt.Host` Swift |
| `setup/macos/*.command` | Deleted (per earlier decision — drop, don't wrap) |
| `setup/linux/lib/*.sh` | Replaced by `Mpd.Virt.KVM` Swift |
| `setup/linux/*.sh` shims | Deleted |
| `setup/windows/lib/*.ps1` | Replaced by `Mpd.Virt.HyperV` Swift (WSL-resident) |
| `setup/windows/lib/common.sh` | Replaced (the OpenSSL-in-WSL CA gen disappears — `Mpd.Core.Certificate` covers it) |
| `setup/windows/setup.cmd` | One-line `wsl -d Debian mpd-virt setup %*` shim or deleted |

`setup/sandbox/` is unchanged — sandbox is a different mode (live-inside-VM,
no host-side binary involved). Its `take-over-sandbox-vm.sh` survives
because the sandbox flow doesn't go through `mpd-virt`.

## Sequencing

1. **Foundation** — `MpdCore` library target added to `Package.swift`,
   `Mpd.Core.Certificate` promoted from `Mpd.Environment.Certificate`,
   `Mpd.Core.WireGuard` added. Existing `mpd` binary gains a dependency
   on `MpdCore`. No behaviour change. ~half a day.
2. **`mpd-virt` skeleton** — new executable target in `Package.swift`,
   new `mpd-virt/` source directory, `Mpd.Virt.Host` shared code,
   `Mpd.Virt.Parallels` backend gated under `#if os(macOS)`. Verb
   stubs return "not implemented" so the CLI parses but doesn't act.
3. **Parallels verbs implemented** — one verb at a time:
   `setup` (the meatiest), then `list`/`start`/`stop`/`doctor`/
   `ssh`/`clone`/`uninstall`. Each verb is testable against a real
   Parallels VM on the dev's Mac.
4. **`Makefile.linux` + Linux/KVM backend** — when the user (or anyone
   else) wants Linux/KVM support. `Mpd.Virt.KVM` gated under
   `#if os(Linux)`.
5. **HyperV backend** — deferred until a Windows user shows up.

Each step ships independently. Step 1 lands as a no-op refactor (the
existing `mpd` binary works identically). Step 2 ships an empty
`mpd-virt`. Step 3's verbs land incrementally. Steps 4–5 are
"whenever."

## Open questions

- **Codesigning / notarization** if `mpd-virt` ever ships outside
  GitHub releases to non-dev users. Apple Developer ID + altool.
  Defer.
- **Per-Mac multiple WG identities**: see state-and-wireguard
  proposal §"Open questions" — same scope concern (whether
  `mac.private` should be exportable for backup).
- **Status-bar app / Dock notifications**: tempting once Swift is
  on the host. Explicitly out of scope here. Could be its own
  follow-up.
- **Linux distro portability** for the KVM backend: today's
  `setup/linux/` strictly gates on Ubuntu 26.04. `Mpd.Virt.KVM`
  can keep that gate or relax it. Decide when KVM backend work
  starts.
