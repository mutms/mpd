# Proposal: `mpd-hpv` — Hyper-V host binary, WSL-resident

A Linux Swift binary that runs inside **WSL2 Debian** and drives
Windows-side Hyper-V via `powershell.exe` interop. Same verb surface
as `mpd-prl` / `mpd-kvm`, same number-to-clipboard sudo-equivalent UX,
same tab completion.

**Cross-cutting design** is owned by
[`host-binary-parallels.md`](host-binary-parallels.md). Implement
`mpd-prl` first; this proposal is the diff against it.

The "WSL-resident" choice is the key architectural decision. An
earlier draft of this proposal targeted native Swift-on-Windows; the
WSL approach is materially simpler in every dimension (toolchain,
build matrix, signing) and inherits the WSL+Debian prereq the existing
`setup.cmd` already imposes.

## Goals

1. One executable on `$PATH` *inside WSL Debian*. `mpd-hpv <verb>`
   from any WSL terminal, or via `wsl mpd-hpv <verb>` from a Windows
   shell.
2. Replace the PowerShell scripts under `setup/windows/lib/*.ps1`
   **and** the WSL bash helper `setup/windows/lib/common.sh` with
   one Linux Swift binary.
3. Reuse `Mpd.Core.Certificate` like the other two host binaries.
4. ArgumentParser-driven tab completion (bash + zsh shims inside WSL).

## Non-goals

- Native Windows binary. Swift-on-Windows is real but the toolchain
  cost + signing requirements aren't worth it for a feature that has
  ~zero Windows users today. WSL is already a hard prereq for the
  current setup; reusing it is free.
- A `.cmd` shim layer over the WSL binary, beyond a trivial entry
  point. The current `setup.cmd` becomes a one-liner: `wsl -d Debian
  mpd-hpv setup`. That's the only Windows-side artifact mpd-hpv
  ships.

## Why WSL-resident

- **Same Swift toolchain as `mpd-kvm`.** Both are Linux binaries. One
  build pattern, one `swiftlang` apt package, one set of `Process()`
  patterns.
- **PowerShell interop is mature.** `powershell.exe` is on `$PATH`
  inside every WSL distro; `wslpath` translates between Linux and
  Windows paths; `cmd.exe`, `clip.exe`, and `route.exe` are all
  callable from WSL.
- **Inherits the existing WSL prereq.** `setup/windows/README.txt`
  already says `wsl --install -d Debian` is required. The current
  bash-in-WSL helper does CA generation there today; mpd-hpv just
  expands that pattern from "one bash file" to "one Swift binary."
- **No Windows code-signing.** ELF binary in WSL; Windows' SmartScreen
  / Authenticode rules don't apply.
- **One less platform target in `Package.swift`.** macOS for
  `mpd-prl`, Linux for both `mpd-kvm` and `mpd-hpv`.

## Architecture

```
┌─────────────────── Windows host ─────────────────────────────┐
│                                                              │
│   Hyper-V VMs (mpd-machine guests, Debian Trixie)            │
│                  ↑                                           │
│                  │ Get-VM / Start-VM / Set-VMMemory /        │
│                  │ Add-DnsClientNrptRule / route.exe /       │
│                  │ Import-Certificate / Set-Clipboard        │
│                  │                                           │
│   powershell.exe ◀── spawned via Process() ──┐               │
│                                              │               │
│   ┌────────────── WSL2 Debian distro ────────┴─────────┐     │
│   │                                                    │     │
│   │   ~/.local/bin/mpd-hpv  (Linux Swift binary)       │     │
│   │   ~/.mpd-machine/<uuid>.env                        │     │
│   │   /mnt/c/Users/<user>/mpd-machine/ca/rootCA.pem    │     │
│   │     (Windows-visible CA path; written via wslpath) │     │
│   │                                                    │     │
│   └────────────────────────────────────────────────────┘     │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

Linux binary, talking to Windows side exclusively via PowerShell
spawn. State files live inside WSL (Linux-native paths).
Cross-visible artifacts (CA cert+key) live on the Windows filesystem
via `/mnt/c/...` so Windows-side tools can read them.

## Backend specifics

### Hyper-V via `powershell.exe`

Swap `mpd-prl`'s `Mpd.PRL.Parallels` namespace (prlctl wrappers) for
`Mpd.HPV.HyperV` inside the `mpd-hpv` target. Swift wrappers that
spawn `powershell.exe -NoProfile -NonInteractive -Command …` via
`Process()`. Cmdlet mapping:

| mpd-prl uses                 | mpd-hpv uses                                                       |
|------------------------------|--------------------------------------------------------------------|
| `prlctl list -a`             | `Get-VM \| Select-Object Id,Name,State \| ConvertTo-Json`          |
| `prlctl status <uuid>`       | `(Get-VM -Id <guid>).State`                                        |
| `prlctl start <uuid>`        | `Start-VM -Id <guid>`                                              |
| `prlctl suspend <uuid>`      | `Suspend-VM -Id <guid>` (or `Save-VM` for save-state)              |
| `prlctl stop <uuid> --kill`  | `Stop-VM -Id <guid> -Force`                                        |
| `prlctl clone <src> --name`  | `Export-VM` + `Import-VM -Copy -GenerateNewId -Path … -Rename`     |
| guest IP discovery           | `(Get-VM <id>).NetworkAdapters.IPAddresses[0]`                     |

Hyper-V VM IDs are GUIDs (36-char dashed, no braces) — same shape
as macOS UUIDs. State files use the GUID as-is.

**Output parsing**: prefer `ConvertTo-Json` on the PowerShell side and
parse Swift-side via `JSONDecoder`. Avoids fragile column-aligned
parsing.

**PowerShell startup overhead**: ~200–500ms per invocation. For
interactive setup, fine. For tighter operations (the doctor's
running-VM enumeration), batch multiple cmdlets into a single
`powershell.exe -Command "…"` invocation.

### Static-IP pinning

The guest is Debian Trixie + GNOME (same as the other backends). The
in-guest NetworkManager keyfile pattern still works; the SSH-driven
provisioning step is identical to `mpd-prl`.

Hyper-V's "Default Switch" gives DHCP-assigned IPs that vary across
host reboots. mpd-hpv creates a private virtual switch on first
setup (`New-VMSwitch -SwitchType Private -Name "mpd-machine-switch"`)
on `10.10.0.0/24`. Static IPs come from the same in-guest NM
keyfile machinery `mpd-prl` uses.

### Host-side networking (via PowerShell)

| Operation              | Spawned PowerShell                                                                  |
|------------------------|-------------------------------------------------------------------------------------|
| Add route (persistent) | `route.exe ADD 10.163.0.0 MASK 255.255.255.0 <vm-ip> -p`                            |
| Split DNS              | `Add-DnsClientNrptRule -Namespace ".mpd.test" -NameServers <vm-ip>`                 |
| Trust the CA           | `Import-Certificate -FilePath "C:\Users\…\rootCA.pem" -CertStoreLocation Cert:\LocalMachine\Root` |
| Firefox CA trust       | system store (since Firefox 49 with `security.enterprise_roots.enabled = true`)     |

Route persistence: `route.exe -p` makes Windows persist automatically
— **no LaunchDaemon equivalent needed**, unlike `mpd-prl`'s macOS
situation. mpd-hpv's `doctor` verb still has value (IP-collision
check, "configured" tag per running VM) but the post-reboot route
refresh is typically a no-op.

### CA generation

Runs inside WSL with the same `Mpd.Core.Certificate.generateCA`
Swift code the other binaries use. Writes the cert + key to a
Windows-visible path under `/mnt/c/Users/<wsl-user>/mpd-machine/ca/`
so PowerShell's `Import-Certificate` can read it. `wslpath -w` does
the Linux→Windows path translation when constructing the
PowerShell command.

WSL→Windows path detection: `cmd.exe /c "echo %USERPROFILE%"` gives
the Windows user-profile path; `wslpath -u` converts it for Linux
side. Cache this once at startup.

### Privilege model — UAC, not sudo

Two patterns the implementation can pick from:

- **(A) Re-launch self elevated**: when a verb detects it needs
  admin, spawn an elevated PowerShell that runs the privileged work.
  ```
  powershell.exe -Command "Start-Process powershell -Verb RunAs -ArgumentList '-Command', '<cmd>'"
  ```
  The UAC prompt appears on Windows side; the WSL Swift binary waits
  for it to complete.
- **(B) Print recipe, user runs in elevated PowerShell**: number-to-
  clipboard via `clip.exe < /tmp/recipe-N`. User opens an admin
  PowerShell and pastes. No UAC popup mid-flow.

Recommendation: **(B)** for the first cut. Cleaner audit trail,
matches the macOS/Linux UX, no surprise UAC popups. (A) is an
optional `--run-elevated` flag if anyone wants the auto-spawn path.

### Clipboard helper

`clip.exe` accepts stdin natively — `printf '%s' "<text>" | clip.exe`
writes to the Windows clipboard. Single-shot, no PowerShell startup
tax. Lives in `Mpd.HPV.Host.Clipboard` inside the mpd-hpv target.

## Build & Package.swift

```swift
.executableTarget(
    name: "mpd-hpv",
    dependencies: ["MpdCore"],
    path: "mpd-hpv",
    condition: .when(platforms: [.linux])    // runs in WSL Debian, not native Windows
),
```

Note `.linux`, **not** `.windows`. mpd-hpv is a Linux ELF binary.

Build inside WSL Debian via `make install` (same as the in-VM `mpd`
binary), installs to `/usr/local/bin/mpd-hpv` or
`~/.local/bin/mpd-hpv`.

## Migration from PowerShell

When `mpd-hpv` lands and is validated, `setup/windows/` collapses to:

```
setup/windows/
└── README.md       # documentation only; points users at `mpd-hpv`
```

Deletions:

- `setup/windows/setup.cmd` / `start.cmd` / `stop.cmd` /
  `uninstall.cmd` — replaced by:
  ```cmd
  @echo off
  wsl -d Debian mpd-hpv setup %*
  ```
  Or just drop the `.cmd` shims entirely and tell users to invoke
  `wsl mpd-hpv setup` from any Windows shell. Same trade-off as the
  macOS `.command` decision (see parallels proposal §"Migration"
  — drop, don't wrap).
- `setup/windows/lib/*.ps1` — gone.
- `setup/windows/lib/common.sh` — gone. The CA-generation-in-WSL
  pattern this file implemented is the literal foundation of the
  mpd-hpv WSL-resident approach; the Swift binary subsumes it.

The cross-platform CA path moves from `%USERPROFILE%\mpd-machine\ca\`
to `%USERPROFILE%\mpd-machine\ca\` (same place, written from WSL via
`/mnt/c/...`). No user-visible change.

## Testing

- Hyper-V is Windows-Pro-only. Need a Windows host with Hyper-V
  enabled + WSL2 + Debian distro. CI cost is significant; rely on
  contributor smoke tests rather than CI.
- Smoke test recipe (inside WSL): `mpd-hpv setup` (clones the cloud
  image, creates the Hyper-V switch, provisions the VM), HTTPS hit,
  `mpd-hpv doctor`, suspend/resume cycle, `mpd-hpv uninstall`.

## Open questions

- **Whether to do at all.** Still the dominant question. The
  WSL-resident approach makes the implementation cost reasonable
  (Linux Swift is the toolchain the implementer already has from
  `mpd-kvm`), so the bar drops. But zero current Windows users
  means the "build it now" case is still weak. Build when a real
  Windows mpd user shows up.
- **WSL → Windows path edge cases.** `wslpath` is reliable for
  user-profile paths but can be fussy with UNC paths, drive
  mappings, and case-sensitive collisions. Worth a defensive helper
  that wraps `wslpath -w`/`-u` with explicit error handling on
  weird inputs.
- **`Export-VM` + `Import-VM` cloning is slow** (full disk copy)
  compared to Parallels'. Hyper-V supports differencing disks but the
  UX is clunky. First-cut: full clone via the export/import
  round-trip. Optimize later if anyone uses it.
- **PowerShell tab completion.** Native PowerShell completion uses
  `Register-ArgumentCompleter`. The mpd-hpv binary lives in WSL, so
  `mpd-hpv <TAB>` works in WSL bash/zsh via ArgumentParser's
  generated completion script. `wsl mpd-hpv <TAB>` from a Windows
  shell doesn't propagate completion through the wsl wrapper —
  acceptable; Windows users who want completion can either invoke
  from a WSL terminal or write a PowerShell completion shim.
