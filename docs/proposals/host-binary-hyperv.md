# Proposal: `mpd-hpv` — Windows host binary for mpd-machine on Hyper-V

A Swift twin of `mpd-prl`, targeting Windows+Hyper-V. Same verb
surface, same number-to-clipboard sudo-equivalent UX, same tab
completion.

**Most speculative of the host-binary trio.** Status today: zero
known Windows users, the existing PowerShell scripts under
`setup/windows/` work, and Swift-on-Windows has a meaningfully rougher
toolchain story than macOS/Linux. **Recommendation: defer until a
Windows user actually shows up** — the maintenance cost of three
host binaries (kvm and hpv) without users is hard to justify. The
PowerShell scripts are a fine endpoint until then.

This proposal documents the design so an interested contributor can
pick it up without re-deriving the spec.

**Cross-cutting design** is owned by
[`host-binary-parallels.md`](host-binary-parallels.md). Implement
`mpd-prl` first; this proposal is the diff against it.

## Goals

1. One executable on `%PATH%`. `mpd-hpv <verb>` from any PowerShell
   or cmd terminal.
2. Replace the PowerShell scripts under `setup/windows/lib/` with
   typed Swift.
3. Drop the PowerShell twin of CA generation — reuse
   `Mpd.Environment.Certificate.generateCA`.
4. Same ArgumentParser-driven tab completion (bash + PowerShell
   completion shims).

## Non-goals

- Replacing the existing `setup.cmd` Finder-equivalent entry point.
  Double-click via Explorer should still work — `setup.cmd` becomes
  a one-line shim that `start "" mpd-hpv setup`.
- WSL-based delivery. mpd-hpv is a native Windows binary; the
  existing `setup/windows/lib/common.sh` (a WSL Debian helper) goes
  away entirely. Swift on Windows is the WSL replacement.

## Why this is the most speculative of the three

- **Swift on Windows is real but newer.** Toolchain install is more
  work (Visual Studio dependencies, SwiftPM less battle-tested),
  fewer libraries, more `#if os(Windows)` carve-outs in shared code.
  Apple's "Swift on Windows" page covers it; expect some friction.
- **No current Windows users** that anyone's aware of. mpd-machine on
  Windows works in principle (the existing PowerShell setup is
  functional) but it's an "in case anyone wants it" path more than a
  daily-driver target.
- **Hyper-V's privilege model differs.** Windows doesn't have
  per-command `sudo`; the typical pattern is whole-process UAC
  elevation via `Start-Process -Verb RunAs`. The sudo-recipe UX from
  `mpd-prl` partially translates (numbered list, copy via
  `Set-Clipboard`), but the "run all via sudo prompt" branch becomes
  "relaunch self elevated" — different shape.

## Backend specifics

### `prlctl` → Hyper-V PowerShell cmdlets

Swap `Mpd.Environment.Host.Parallels.PRLCtl` for
`Mpd.Environment.Host.HyperV.PSCmdlets` — Swift wrappers that spawn
`powershell.exe -NoProfile -NonInteractive -Command …` via
`Process()`. Cmdlet mapping:

| mpd-prl uses                 | mpd-hpv uses                                                |
|------------------------------|-------------------------------------------------------------|
| `prlctl list -a`             | `Get-VM \| Select-Object Id,Name,State`                     |
| `prlctl status <uuid>`       | `(Get-VM -Id <guid>).State`                                 |
| `prlctl start <uuid>`        | `Start-VM -Id <guid>`                                       |
| `prlctl suspend <uuid>`      | `Suspend-VM -Id <guid>` (or `Save-VM` for save-state)       |
| `prlctl stop <uuid> --kill`  | `Stop-VM -Id <guid> -Force`                                 |
| `prlctl clone <src> --name`  | export + import via `Export-VM` / `Import-VM` with rename   |
| guest IP discovery           | Hyper-V Integration Services: `(Get-VM <id>).NetworkAdapters.IPAddresses[0]` |

Hyper-V VM IDs are GUIDs, formatted with dashes (no braces). State
files use the GUID as-is — same shape as macOS UUIDs.

### Static-IP pinning

The guest is Debian Trixie + GNOME — same as the other backends. The
in-guest NetworkManager keyfile pattern still works; the SSH-driven
provisioning step is identical to `mpd-prl`.

Hyper-V's "Default Switch" gives DHCP-assigned IPs that vary across
host reboots. mpd-hpv would need to either:

- Use a custom internal virtual switch with a known subnet (like
  Parallels Shared's 10.211.55.0/24), or
- Bind a static IP inside the guest regardless of what DHCP would have
  given.

Today's PowerShell setup creates a "mpd-machine-switch" private
switch on 10.10.0.0/24. Carry that forward — `mpd-hpv setup` runs
`New-VMSwitch` if absent.

### Host-side networking (the biggest delta)

Windows differs from both macOS and Linux:

| Operation                  | macOS                                              | Windows                                                                          |
|----------------------------|----------------------------------------------------|----------------------------------------------------------------------------------|
| Add route                  | `route -n add -net 10.163.0.0/24 <vm-ip>`          | `route.exe ADD 10.163.0.0 MASK 255.255.255.0 <vm-ip> -p` (`-p` = persistent)     |
| Split DNS                  | `/etc/resolver/mpd.test`                           | NRPT rule: `Add-DnsClientNrptRule -Namespace ".mpd.test" -NameServers <vm-ip>`   |
| Trust the CA               | `security add-trusted-cert -k System.keychain …`   | `Import-Certificate -FilePath … -CertStoreLocation Cert:\LocalMachine\Root`      |
| Firefox CA trust           | System keychain                                    | Either system store (since Firefox 49 with `security.enterprise_roots.enabled`) or an enterprise policy at `HKLM\Software\Policies\Mozilla\Firefox` |
| Persistent route           | (deferred)                                         | `-p` flag makes Windows persist it automatically — no LaunchDaemon equivalent needed |

The Windows route is automatically persisted with `route.exe -p`, so
the "doctor after host reboot" problem mpd-prl has *doesn't exist*
here. mpd-hpv's `doctor` verb still has value (IP-collision check,
"configured" tag per running VM), but the route refresh step is
typically a no-op.

### CA model

The Windows host has always had a single CA location —
`%USERPROFILE%\mpd-machine\ca\rootCA.pem` — because the repo doesn't
live on the Windows side (cloned inside the VM only). No mirror to
remove. `mpd-hpv setup` generates or reuses that single file via
`Mpd.Environment.Certificate.generateCA`, trusts it in
`Cert:\LocalMachine\Root`, and that's it.

Uninstall follows the parallels model: print the `Remove-Item …` /
`Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -match
"mpd.test" | Remove-Item` line as part of the number-to-clipboard
recipe (Windows variant uses `Set-Clipboard`); user picks which to
run. Orphan trust-store entries are name-constrained to `*.mpd.test`
and harmless if left.

See `host-binary-parallels.md` §"CA model" for the full rationale.

### Privilege model — UAC, not sudo

Windows has no per-command privilege elevation. Two reasonable
patterns:

- **(A) Re-launch self elevated**: when a verb detects it needs admin,
  it spawns a second copy of itself via
  `Start-Process -Verb RunAs mpd-hpv … --elevated`. The elevated
  copy runs the privileged work and exits; the original waits for it
  and resumes.
- **(B) Print recipe, user runs in elevated PowerShell**: number-to-
  clipboard, same as mpd-prl. The user opens an admin PowerShell and
  pastes. No re-launch dance.

Recommendation: **(B)** for the first cut. Cleaner audit trail
("here's what's about to happen, paste it"), no UAC popup mid-flow,
matches the macOS/Linux UX.

### Clipboard helper

Spawn `powershell -Command "Set-Clipboard -Value '<text>'"` for the
copy step. `LinuxClipboard`'s xclip/wl-copy detection logic doesn't
apply here.

### Swift toolchain on Windows

- Install: see https://www.swift.org/install/windows/ — winget or
  manual installer + Visual Studio Build Tools. Heavier than `apt
  install swiftlang` on Debian.
- `swift build` works for executable targets on Windows.
- `Process()` is supported. File APIs (`FileManager`, `String(contentsOfFile:)`)
  work. UNC paths and Windows path conventions need care.
- Static linking: prefer it (avoids Swift runtime DLL dependency on
  end-user machines). `swift build -c release --static-swift-stdlib`.
- Code signing: required for non-warning install. Defer until users.

## Build & Package.swift

```swift
.executableTarget(
    name: "mpd-hpv",
    dependencies: ["Mpd.Shared"],
    path: "mpd-hpv",
    condition: .when(platforms: [.windows])
),
```

`make install` doesn't run on Windows. Distribution path probably ends
up as a GitHub release artifact (zipped Swift-built binary). Defer
until users.

## Migration from PowerShell

- `setup/windows/setup.cmd` / `start.cmd` / `stop.cmd` /
  `uninstall.cmd` become one-line shims:
  ```
  @echo off
  mpd-hpv setup %*
  ```
- `setup/windows/lib/*.ps1` and `setup/windows/lib/common.sh` (WSL
  helper) deleted after Swift verbs land and are validated.
- The WSL Debian dependency for CA generation (`setup/windows/lib/
  common.sh` running OpenSSL in WSL) goes away — Swift generates the
  CA directly via `Mpd.Environment.Certificate.generateCA`. One less
  moving part on Windows.

## Testing

- Hyper-V is Windows-Pro-only. CI would need a Windows runner with
  Hyper-V enabled. Cost / complexity argues for relying on contributor
  smoke tests rather than CI.
- Smoke test: clone the Debian Trixie cloud image via `mpd-hpv setup`,
  verify HTTPS, `doctor`, `stop`, `start`, `uninstall`. Document the
  recipe in `setup/windows/README.txt` once mpd-hpv exists.

## Open questions

- **Whether to do at all.** See top of this file. The PowerShell
  scripts work. mpd-hpv replaces them mostly for code-organization
  reasons (one Swift codebase across hosts) — not because the
  PowerShell is broken. If you, the implementer reading this, are
  the first Windows mpd user: PowerShell is fine. Build mpd-hpv if
  you want to maintain it long-term; otherwise contribute fixes to
  the existing PowerShell.
- **WSL2 vs. native Hyper-V VM.** The user-facing question of whether
  mpd-machine on Windows means "Hyper-V VM" or "WSL2 distro" has
  always tilted toward Hyper-V (real VM, real isolation; see
  [`setup/README.md`](../../setup/README.md) §"What's not here").
  Carry that forward.
- **`virt-clone`-style fast cloning.** Hyper-V's `Export-VM` +
  `Import-VM` is slow (full disk copy) compared to Parallels' clone.
  Hyper-V supports differencing disks but the UX is clunky. Initial
  implementation: full clone. Optimize later if anyone uses it.
- **PowerShell-side completion.** Native PowerShell tab completion
  uses `Register-ArgumentCompleter`. ArgumentParser doesn't generate
  PowerShell completion natively; could either auto-translate from
  the bash completion script or hand-write a `.ps1` shim. Defer.
