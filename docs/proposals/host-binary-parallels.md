# Proposal: `mpd-prl` — macOS host binary for mpd-machine on Parallels

Replace the bash scripts under `setup/macos/lib/` with a native macOS
Swift binary. Same user-facing surface (setup / doctor / uninstall),
plus a few new verbs that bash never gave us cleanly (`list`, `start`,
`stop`, `ssh`, `clone`).

This proposal is also the **reference spec** for the host-binary trio.
The sibling proposals `host-binary-kvm.md` and `host-binary-hyperv.md`
delegate cross-cutting design (verb surface, namespace tree,
sudo-recipe UX, state-file layout, completion contract) to this
document and spec only the backend-specific deltas.

## Goals

1. One executable on `$PATH` everywhere on macOS. `mpd-prl <verb>` from
   any terminal, any directory. No hunting for `.command` files in
   Finder.
2. Eliminate the **bash twin** of `Mpd.Environment.Certificate.generateCA`
   (today's `generate_mpd_ca` in `setup/macos/lib/common.sh`). Two
   implementations of CA generation must stay byte-identical (DN,
   v3_ca extensions, name constraints) or local trust silently breaks
   — a real maintenance hazard.
3. ArgumentParser-driven **tab completion** for verbs and dynamic VM
   names (mirror `mpd`'s existing completion machinery).
4. The **number-to-clipboard sudo-recipe UX** invented in mpd-desktop's
   setup — numbered list of required `sudo` commands, digit copies the
   line via `pbcopy`, lower friction than "press Enter and let the
   script sudo for you."
5. Reduce review surface — Swift diffs are easier to follow than the
   dense bash that grew around UUID-keyed state files, sudo recipes,
   and interactive pickers.

## Non-goals

- Replace `mpd-desktop` (the macOS-native Podman Desktop + WireGuard
  binary). It stays as its own product with its own roadmap.
- Replace the in-VM `mpd` binary. Linux build is unchanged.
- Cross-platform autodetection. Each host binary targets one
  hypervisor; the user picks which they want.
- A `.app` bundle / Dock icon / SwiftUI menu-bar app. CLI binary only.
  A native macOS UI (SwiftUI app, or Automator-generated `.app`)
  belongs in a follow-up proposal; the CLI must stand on its own
  first.
- Finder `.command` shims. They're dropped when this lands — see
  "Migration" below. The Finder-double-click affordance returns
  later via the SwiftUI/Automator proposal, not as bash wrappers.
- Distribution outside `make install`. No Homebrew formula, no
  notarized installer (defer until a non-dev user asks).

## Why now

The bash under `setup/macos/lib/` got dense. The UUID-keyed state
refactor in particular leans on hand-rolled `awk` for env-file parsing
across five scripts, with the same "for envfile in *.env" pattern
duplicated. Swift collapses that into typed I/O and an enumerator.

The CA-twin issue is the strongest single argument. Today
`generate_mpd_ca` in `common.sh` and `Mpd.Environment.Certificate.generateCA`
in Swift must produce certs with identical DN, extensions, and name
constraints. Drift breaks browser trust silently. One Swift
implementation eliminates the class of bug.

## Binary distribution

- Built by `swift build` via a new `executableTarget` named `mpd-prl`
  in `Package.swift`, macOS-only (`condition: .when(platforms: [.macOS])`
  or `#if os(macOS)` guards).
- `make install` produces `bin/mpd-prl` and `sudo ln -sf $PWD/bin/mpd-prl
  /usr/local/bin/mpd-prl` — same dance as today's `mpd`.
- The existing `.command` shims under `setup/macos/` get **deleted**
  when `mpd-prl` lands. The whole point of putting a binary on `$PATH`
  is to stop hunting for `.command` files. Bash-wrappers-around-a-Swift-
  binary is the worst of both worlds.
- Finder double-click users get pointed at the future SwiftUI / Automator
  proposal (not yet written). Until that ships, those users open
  Terminal and type `mpd-prl <verb>`. Acceptable regression — Finder
  affordance was already a corner-case path.
- The auto-generated `~/Desktop/mpd-machine.command` desktop shortcut
  also goes away. `mpd-prl ssh` (with no arg, uses current VM) is the
  Terminal-native replacement.

End-state shape of `setup/macos/`:

```
setup/macos/
└── README.md       # documentation only; points users at `mpd-prl`
```

No `lib/`, no `.command` files. Everything else lives in `mpd-prl/`
(Swift sources) at the repo root.

## User-facing verb surface

| Verb | Args | What it does |
|---|---|---|
| `setup` | — | Interactive new-VM creation or switch-to-existing flow. Same picker UX as today's `setup.command`. |
| `doctor` | — | List all tracked VMs + states + "configured" tag. If exactly one is running, verify/re-apply host route + DNS + CA. If >1 running, warn and exit. Same logic as today's `doctor.command`. |
| `uninstall` | `[--yes]` | Tear down host networking + state files. Per-VM y/N prompt (or `--yes` for non-interactive). |
| `list` | `[--json]` | Print tracked VMs as a table. JSON variant for scripting. |
| `start` | `<vm>` | Boot the VM via `prlctl start`. If a different mpd VM is running, suspend it first (one-running-at-a-time). Re-apply host networking to the new VM's IP. Updates `current.env`. Idempotent. |
| `stop` | `<vm>` | Suspend the VM via `prlctl suspend`. (Hard stop on `--kill`.) |
| `ssh` | `<vm> [-- cmd …]` | SSH into the VM. With trailing args, run a one-shot command. |
| `clone` | `<src-vm> <new-name>` | `prlctl clone <src> --name <new>`, capture new UUID, write new `~/.mpd-machine/<uuid>.env`. The clone inherits the src's pinned static IP (in-guest NM keyfile); user runs `start` to switch host networking. |

The `<vm>` placeholder accepts either a friendly Parallels name or a
UUID. Completion resolves to the *current* Parallels name for each
tracked UUID (via `prlctl list <uuid> -o name --no-header`), so a
rename in the Parallels GUI shows up in completion immediately.

## Argument & completion contract

Use Swift ArgumentParser (already in use by `mpd`). Per-verb structure
mirrors `mpd`'s pattern:

```swift
struct Start: ParsableCommand {
    @Argument(
        help: "VM friendly name or UUID.",
        completion: .custom { _ in trackedVMNames() }
    ) var vm: String
}
```

`trackedVMNames()` reads `~/.mpd-machine/*.env`, calls
`prlctl list <uuid> -o name --no-header` for each, returns the current
names. Same approach `mpd start <project>` uses today.

Completion shims (zsh, bash) ship via `mpd-prl --generate-completion-script
zsh|bash`, installed by `make install` into the standard locations.

## Sudo-recipe UX spec

The bash `print_sudo_recipe` in `setup/macos/lib/common.sh` prints the
needed `sudo` commands and offers two paths: press Enter to let the
script sudo, or copy-paste manually in another terminal.

mpd-desktop's setup invented a richer variant that the user calls out
as a primary motivation here. Spec:

1. Print a numbered list of the privileged commands, one per line,
   with explanatory comments where useful.
2. Read a single character (no Enter needed):
   - A digit `1`–`9` → copy that command to the macOS pasteboard via
     `Process(["pbcopy"])`, print "copied — paste it in another
     terminal, then press Enter when done." Re-prompt.
   - `a` → run all commands via `sudo -v` + per-command Process()
     invocations. Drop creds via `sudo -k` after.
   - `q` → abort.
3. After each manual copy-and-run, re-detect what's still needed.
   If the user fixed everything by hand, exit without prompting again.

Centralize this in `Mpd.Environment.Host.SudoRecipe` so kvm and hpv
can reuse it (the kvm one calls `xclip -selection clipboard` or
`wl-copy` instead of `pbcopy`; hpv uses `Set-Clipboard` via
PowerShell). The protocol:

```swift
protocol ClipboardWriter {
    func write(_ text: String) throws
}
```

Per-platform impl: `MacOSPasteboard`, `LinuxClipboard` (auto-detects
xclip/wl-copy), `WindowsClipboard`.

## Swift namespace layout

Add a third sibling under `Mpd.Environment`, parallel to existing
`Desktop` and `Machine`:

```
Mpd
├── Core                            # platform-agnostic (existing)
├── Environment
│   ├── Desktop                     # mpd-desktop (existing, macOS-only)
│   ├── Machine                     # mpd-machine in-VM (existing, Linux-only)
│   └── Host                        # NEW: host-side drivers for mpd-machine
│       ├── (sudo-recipe printer)   # shared across backends
│       ├── (clipboard helper)      # shared, platform-specific impls
│       ├── (state file reader)     # shared
│       ├── (route abstraction)     # protocol; per-OS impls
│       └── Parallels               # macOS-only
│           ├── PRLCtl              # wrapper around `prlctl`
│           ├── Setup               # create / clone / configure verb impls
│           ├── Doctor              # health check
│           └── Lifecycle           # start / stop / suspend / ssh
├── Runtime                         # existing
├── Service                         # existing
└── CLI                             # existing
```

Shared host-side code (sudo recipe, clipboard, state files, route
abstraction protocol) lives at `Mpd.Environment.Host`. Backend
specifics (PRLCtl, libvirt, Hyper-V) live under
`Mpd.Environment.Host.<Backend>`.

Pull `Mpd.Core` + `Mpd.Environment.Certificate` into a shared library
target in `Package.swift` so both `mpd` and `mpd-prl` (and future
`mpd-kvm`/`mpd-hpv`) link against it without duplication. Half-day
refactor; pays dividends regardless of whether kvm/hpv ever ship.

## State files

Mostly carried forward from today's UUID-keyed bash design (see
`setup/macos/lib/common.sh`), with **one simplification**: drop the
`~/.mpd-machine/ca/` mirror entirely. `~/Developer/mpd/conf/caroot/`
is the only on-host location for the CA keypair. See
"CA model" below for the rationale.

Files in scope:

- `~/.mpd-machine/<uuid>.env` — one per tracked VM. Contents:
  ```
  MPD_VM_UUID=<uuid-with-braces-stripped>
  MPD_VM_NAME=<snapshot of friendly Parallels name at write time>
  MPD_VM_IP=<static IP in 10.211.55.0/24>
  MPD_VM_USER=<dev user inside the VM>
  ```
- `~/.mpd-machine/current.env` — pointer file. Same shape as a
  `<uuid>.env`. `MPD_VM_UUID` is the source of truth for "which VM is
  active." Re-derivable from the host route's gateway IP via the env
  files if `current.env` is missing.
- `~/Developer/mpd/conf/caroot/{rootCA.pem,rootCA-key.pem}` —
  canonical CA location, shared with mpd-desktop. The only on-host
  copy.

Gone vs. today's bash:

- ~~`~/.mpd-machine/ca/rootCA.pem` + `rootCA-key.pem`~~ (mirror removed).
- ~~`~/.mpd-machine/ca.sha1`~~ (no longer needed — see below).

State writes go through a typed Swift struct:

```swift
struct VMState: Codable {
    let uuid: String
    let name: String
    let ip: String
    let user: String
}
```

Serialized as the same `KEY=VALUE` flat-file format the bash uses, so
existing installs keep working without migration.

## CA model

Today's bash has a five-branch `prepare_host_ca()` that mirrors the
CA between `~/Developer/mpd/conf/caroot/` and `~/.mpd-machine/ca/`,
recovers each side from the other, and on uninstall keeps the keychain
trust iff `caroot/` still exists. It works but earns its complexity in
edge cases that effectively never happen.

`mpd-prl` collapses this to:

- **`~/Developer/mpd/conf/caroot/` is the only on-host location.** If
  it exists, reuse. If it doesn't, generate fresh via
  `Mpd.Environment.Certificate.generateCA`. No mirror, no five-branch
  resolution table.
- **`mpd-prl setup`** generates or reuses caroot, uploads it into the
  VM, trusts it in the System Keychain. Single forward flow.
- **`mpd-prl uninstall`** never touches the keychain on its own. It
  prints the `sudo security delete-certificate` line as part of the
  number-to-clipboard recipe; user runs it (or doesn't). Orphan
  keychain certs are harmless — the CA's name constraints lock it to
  `*.mpd.test`, so a leftover cert can't sign anything dangerous.

This matches `mpd --uninstall` (mpd-desktop)'s existing convention: it
prints a manual cleanup recipe for keychain trust, doesn't auto-execute.
Two host-side products converge on one model.

Side-effect: `Mpd.Environment.mpdMachineCARootDir` (the Swift constant
pointing at `~/.mpd-machine/ca/`) goes away, and
`DesktopActionSetup`'s adoption-from-mirror code path can be deleted
when mpd-prl lands. Tiny win for mpd-desktop's code surface too.

## Per-verb implementation sketches

### `setup`

Today's `setup/macos/lib/setup.sh` flow, transcribed:

1. Preflight: Parallels Desktop installed, `prlctl` exists, template
   `mpd-machine-template` exists, host tools available, SSH key
   present (generate if missing).
2. Pick existing VM (UUID-keyed picker) or `n` for new.
3. New-VM path:
   - Prompt for octet (`.100`–`.254`), reject if already used by a
     tracked VM.
   - Prompt for username, memory, disk.
   - **CA prep**: `prepare_host_ca()` — read existing caroot or
     generate. Uses `Mpd.Environment.Certificate.generateCA` (the
     reuse win).
   - **Host-side fenced sudo**: route + resolver + CA trust, presented
     via the number-to-clipboard recipe.
   - **Clone + provision**: `prlctl clone`, capture UUID, set
     memory/cpus/disk, start VM, wait for Parallels Tools IP, SSH in,
     rename hostname, pin static IP via NetworkManager keyfile, push
     CA, run `mpd --setup` in the VM, install motd.
4. Existing-VM re-verify or switch (suspend current, start target,
   re-apply host networking).
5. State refresh: `set_mpd_ssh_config`, `write_mpd_current_env`,
   `ensure_desktop_shortcut`.

### `doctor`

Today's `doctor.sh` flow, transcribed to typed Swift. Logic
unchanged.

### `uninstall`

Per-VM delete prompts as today's bash, **minus the auto-keychain-cleanup
logic**. The flow:

1. Print the host-state inventory (route, resolver, ssh-config block,
   `~/.mpd-machine/`, desktop shortcut, keychain CA cert).
2. Confirmation gate (`Type YES`).
3. Apply destructive operations via the number-to-clipboard recipe:
   - `sudo route -n delete -net 10.163.0.0/24`
   - `sudo rm -f /etc/resolver/mpd.test`
   - `sudo security delete-certificate -t -c "<subject>" /Library/Keychains/System.keychain`
   The user can pick which lines to run. Keychain cleanup is one
   line among the rest — no auto-detect-and-skip heuristic.
4. Local-only cleanup (no sudo): `rm -rf ~/.mpd-machine/`, strip the
   SSH config block, remove `~/Desktop/mpd-machine.command` if it
   exists.
5. Per-VM `prlctl delete` prompts (default: keep).

The CA-in-caroot-stays-untouched: `~/Developer/mpd/conf/caroot/` is
**never** deleted by uninstall. Same as today (and same as
`mpd --uninstall` for mpd-desktop). Mention it in the printed
summary so the user knows where to delete it from if they want a
true reset.

### `list`

Walk `~/.mpd-machine/*.env`, ask `prlctl list <uuid> -o name,status
--no-header` for each, print as a table. `--json` for scripting. Same
output `get_mpd_vms` produces today.

### `start <vm>`

1. Resolve `<vm>` → UUID (accepts name or UUID).
2. If a different mpd VM is currently `running`, suspend it
   (one-running-at-a-time invariant).
3. `prlctl start <uuid>`. Poll `prlctl status` until `running`.
4. Wait for SSH on the VM's tracked IP.
5. Update `current.env` to point at this UUID.
6. Re-apply host networking (route + resolver + CA — same as
   `doctor`'s post-pick path).
7. Refresh the SSH config alias (`Host <current-name>`) — the VM may
   have been renamed in Parallels since last setup.

### `stop <vm>`

`prlctl suspend <uuid>`. With `--kill`, `prlctl stop <uuid> --kill`.
No host-side mutation.

### `ssh <vm> [-- cmd …]`

Resolve `<vm>` → UUID → IP + user → `Process(["ssh", "<user>@<ip>", …])`.
With trailing args after `--`, pass through as the remote command.

### `clone <src-vm> <new-name>`

1. Resolve `<src-vm>` → UUID.
2. Refuse if source is running (Parallels can't clone a live VM
   without snapshot dance).
3. `prlctl clone <src-uuid> --name <new-name>`.
4. Capture new UUID via `prlctl list <new-name> -o uuid --no-header`.
5. Write `~/.mpd-machine/<new-uuid>.env`, inheriting IP/user from
   src's env file (the in-guest NM keyfile gives the clone the same
   static IP — that's the "branching" workflow).
6. Don't auto-switch host networking. User runs `mpd-prl start
   <new-name>` to make the clone active.

## Migration from bash

When `mpd-prl` lands and is validated, `setup/macos/` collapses to a
single `README.md`. The deletions happen in a separate commit from
the Swift additions so bisecting stays clean. Concretely:

- Delete `setup/macos/setup.command`, `doctor.command`,
  `uninstall.command`. CLI replacement: `mpd-prl setup` / `mpd-prl
  doctor` / `mpd-prl uninstall`.
- Delete `setup/macos/lib/*.sh` (every helper script).
- The auto-generated `~/Desktop/mpd-machine.command` shortcut is no
  longer created by setup. Existing ones on user Desktops keep
  working until the user removes them (the bash inside still
  ssh's via the shape we built — independent of `mpd-prl`); next
  `mpd-prl setup` deletes them and doesn't replace them.
- Rewrite `setup/macos/README.md` to point at `mpd-prl` for every
  workflow (today it documents the `.command` files).
- Existing `~/.mpd-machine/*.env` files keep working unchanged
  (bash and Swift both consumed the same `KEY=VALUE` shape — the
  migration is invisible to existing installs).
- `~/Developer/mpd/conf/caroot/` keeps the same content and layout —
  bash and Swift both generate the same cert.

A Finder-double-click affordance can come back later as its own
proposal (SwiftUI app, Automator-built `.app` bundle, or both). Out
of scope for `mpd-prl` itself.

## Package.swift changes

1. Add a `Mpd.Shared` library target containing `Mpd.Core` +
   `Mpd.Environment.Certificate` + `Mpd.Environment.Host.*`
   (cross-cutting host-side code).
2. Existing `mpd` executable depends on `Mpd.Shared`.
3. New `mpd-prl` executable depends on `Mpd.Shared` +
   `Mpd.Environment.Host.Parallels`.
4. Both executables compile from the same sources; only the entry
   point and the per-target `Mpd.CLI` command surface differ.

```swift
// sketch
let package = Package(
    name: "mpd",
    targets: [
        .target(
            name: "Mpd.Shared",
            path: "mpd/Shared"
        ),
        .executableTarget(
            name: "mpd",
            dependencies: ["Mpd.Shared"],
            path: "mpd",
            exclude: ["Shared"]
        ),
        .executableTarget(
            name: "mpd-prl",
            dependencies: ["Mpd.Shared"],
            path: "mpd-prl",
            condition: .when(platforms: [.macOS])
        ),
    ]
)
```

## Testing

- **Unit tests**: state-file parser, sudo-recipe printer, clipboard
  helper. All side-effect-free.
- **Smoke test**: clone the template via `mpd-prl setup`, verify HTTPS
  hit, `mpd-prl doctor`, `mpd-prl stop`, `mpd-prl start`,
  `mpd-prl uninstall --yes`. Document the recipe in `AGENTS.md`
  under "Pre-release validation."
- **Boundary guards**: existing `make check` rules (HostExec,
  mpdenv-source, privilege) apply to any new shell assets. The new
  Swift code is covered by the existing HostExec rule (which restricts
  `Process()` to `mpd/Environment/Desktop/HostExec.swift` and
  `mpd/Environment/Machine/HostExec.swift` — extend with the macOS
  Host equivalent).

## Open questions

- **Single Mpd.Shared library or `Mpd.Core` + `Mpd.Environment.Host`
  as two separate library targets?** Two is technically cleaner
  (Core is platform-agnostic, Host is "host-side, OS-specific"); one
  is simpler to manage. Decide based on whether you eventually want
  `Mpd.Core` consumed by anything else.
- **Codesigning / notarization** if `mpd-prl` ever gets distributed
  outside `make install`. Apple Developer ID + altool dance. Defer.
- **Status-bar app / Dock notifications.** Tempting once Swift is on
  the host; explicitly out of scope here. Could become its own
  proposal later.
