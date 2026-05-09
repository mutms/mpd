# PLAN — platform parity for mpd-machine

Working doc. Delete when done.

Goal: settle the `mpd-machine` platform set on four — three "host
reaches into a VM" automated bootstraps (macos-utm, ubuntu-kvm,
windows-hyperv) plus a "graphical sandbox" path (sandbox) where the
user lives inside the VM and the host stays untouched. Drop generic-vm
along the way. Prune the now-dead Swift surface that only existed to
serve generic-vm's "host has a different OS than the VM" laptop
recipes.

## Status

**Done (in `main`):**
- **macos-utm overhaul** — `uninstall.sh` rewritten (sudo recipe + per-VM
  `[y/N]` last + `-c "$CN" -t` cert deletion that drains duplicates
  with admin trust settings); `configure-client.sh` rewritten with the
  same recipe affordance for route + resolver + CA; `prepare_host_ca`
  mirrors one CA across `~/Developer/mpd/conf/caroot/` and
  `~/.mpd-machine/ca/`, no more ephemeral/scratch-dir CAs.
- **Swift CA mirror** — `DesktopActionSetup` adopts from
  `~/.mpd-machine/ca/` when caroot/ is missing; `Mpd.Environment.mpdMachineCARootDir`
  exposes the path (read-only from Swift). `MachineActionSetup.installLoginBanner`
  centralizes the `/etc/motd` install (was duplicated in each
  `create-vm.sh`). New `PlatformKind.ubuntuKVM` raw value.
- **ubuntu-kvm platform shipped** — Phase 1 complete. See condensed
  note below.
- **Doc consolidation** — `ARCHITECTURE.md` §"Sister rule" generalized
  to macos-utm + ubuntu-kvm; the host-only-trust boundary rule
  documented in `machine/SECURITY.md` and `desktop/SECURITY.md`;
  `ROADMAP.md` parked-bullet removed; `machine/{README,USAGE}.md`
  enumerate ubuntu-kvm alongside the other automated platforms.

## Invariants (apply to all managed platforms)

1. **Single host CA, mirrored across two real-file locations.**
   - Canonical: `~/Developer/mpd/conf/caroot/{rootCA.pem,rootCA-key.pem}`
     — shared with mpd-desktop on macOS; only populated when
     `~/Developer/mpd/conf/` exists.
   - Platform: `~/.mpd-machine/ca/{rootCA.pem,rootCA-key.pem}` —
     always populated after first managed-platform setup. (On Linux we
     keep the dotfile name for cross-platform symmetry; on Windows the
     files live inside the WSL distro's home, see Phase 2.)
   - Installers mirror on every run; wiping either side auto-restores
     from the other.
2. **Host-only trust rule.** CAs flow host → VM only. Managed installers
   never pull a CA off a VM into the host trust store. `sandbox` doesn't
   touch the host trust store at all — both the CA and its trust live
   strictly inside the VM, so the rule is satisfied trivially.
3. **Sudo recipe affordance.** Before any privileged operation: print
   the exact runnable commands; let the dev choose `(a)` run yourself
   in another terminal then press Enter, or `(b)` press Enter and let
   the script sudo. After the pause, re-detect; apply only what's
   still needed; drop cached creds with `sudo -k`. Reference:
   `macos-utm/lib/common.sh::print_sudo_recipe`.
4. **Per-VM `[y/N]` deletion in uninstall, as the last step.** Default
   keep. Ctrl-C during the loop leaves the host fully cleaned up and
   the remaining VMs intact. *(Applies to the three host-managed
   platforms — macos-utm, ubuntu-kvm, windows-hyperv. `sandbox` has
   no platform installer to uninstall: VM lifecycle is the
   hypervisor's job, project lifecycle is `mpd --uninstall`.)*

## Phase 1 — `ubuntu-kvm` — DONE

Shipped on Ubuntu 26.04 LTS. Full lifecycle (`setup` / `start` /
`stop` / `uninstall`) wired against libvirt + KVM with the same
sudo recipe affordance and per-VM `[y/N]` uninstall pattern as
macos-utm. Documented in
[`mpd-machine/platforms/ubuntu-kvm/README.md`](mpd-machine/platforms/ubuntu-kvm/README.md).
Sister-rule generalization, ROADMAP cleanup, and machine docs all
landed.

## Phase 2 — `windows-hyperv` WSL refactor (Windows host)

Move cert generation + cloud-init seed prep from PowerShell into WSL
bash. Hyper-V cmdlets, Windows trust store import, NRPT DNS, persistent
route stay in PS — they have no WSL substitute. PowerShell encoding
pain on `openssl` and YAML goes away.

**Prereq:** `wsl --install -d Debian` (confirmed to land Trixie). The
script asserts WSL2 + a Debian distro before doing CA work.

**Files to touch** (under `mpd-machine/platforms/windows-hyperv/`):
- `setup.cmd` / `start.cmd` / `stop.cmd` / `uninstall.cmd` — entry
  shims; same UAC gate.
- `lib/common.ps1` — slim to Hyper-V + trust + DNS NRPT + route + WSL
  invocation helpers (`Invoke-WSL`, path translation `Convert-WSLPath`).
- `lib/common.sh` — **new**. Port `generate_mpd_ca`, `copy_ca_files`,
  `prepare_host_ca` (Linux-ized: no `/Library/Keychains` references).
  Self-contained — duplicate from macos-utm per the platforms
  self-containment rule, don't symlink.
- `lib/setup.ps1` — call WSL bash for cert prep + cloud-init seed,
  then PS for VM creation + trust import.
- `lib/create-vm.ps1` — VHDX creation stays PS; cloud-init seed file
  content comes from WSL bash.
- `lib/configure-client.ps1` — DNS NRPT + route stays PS; trust import
  reads `\\wsl$\Debian\home\<user>\.mpd-machine\ca\rootCA.pem` and
  imports via `Import-Certificate -CertStoreLocation Cert:\LocalMachine\Root`.
- `lib/uninstall.ps1` — adopt the per-VM `[y/N]` pattern. UAC is a
  single elevation gate per script (whole body is the "fenced section"
  by design — no per-op recipe affordance applies).

**Path conventions:**
- Bash sees `~/.mpd-machine/ca/rootCA.pem` inside the WSL distro home.
- PS sees the same file at `\\wsl$\Debian\home\<user>\.mpd-machine\ca\rootCA.pem`.
- No Windows-side mirror beyond WSL. mpd-desktop is macOS-only, so
  there's no second consumer that needs a Windows-native path.

**Definition of done:**
- Fresh Win+Hyper-V bootstrap end-to-end on a clean Win 11 Pro install
  (with WSL2 prereq).
- Invariants 1 (mirror — single-location since no caroot/ on Windows),
  2 (host-only — cert generated in WSL on the host, not in the VM),
  4 (per-VM uninstall) all exercised. Invariant 3 (recipe affordance)
  is replaced by the UAC gate.
- No `openssl` or cloud-init YAML in PS.
- README.txt updated with WSL prereq + path map.
- `docs/ARCHITECTURE.md` §"Sister rule" mentions windows-hyperv-via-WSL
  as a sibling pattern.

## Phase 3 — `sandbox` platform + drop `generic-vm`

New **graphical sandbox mpd-machine** platform: user installs Ubuntu
26.04 desktop in their hypervisor of choice (UTM / Hyper-V /
VirtualBox / virt-manager / VMware), takes a snapshot, runs one
script inside the VM. mpd lives entirely in the VM; the host gets
zero DNS/route/trust changes. UX is "open the VM window, you're at
a GNOME desktop with Firefox open on `https://mpd.test`."

The hypervisor owns VM lifecycle (start/stop/snapshot from its GUI);
mpd inside owns project lifecycle. So no `setup.sh`/`start.sh`/
`stop.sh`/`uninstall.sh` shim quartet — just one `provision.sh`.

**Files to create** (under `mpd-machine/platforms/sandbox/`):
```
README.md            # "install Ubuntu 26.04 desktop, snapshot, run provision.sh"
provision.sh         # ~150 lines: preflight + apt deps + mpd build + mpd --setup
```

**Conventions:**
- **Target: Ubuntu 26.04 LTS** with the standard GNOME desktop install.
  Other distros work mechanically (apt-family-only); refuse on
  non-26.04 in preflight.
- **Swift toolchain confirmed**: `swiftlang` from Ubuntu 26.04's apt
  repos compiles mpd clean (Swift 6.1, zero warnings). No need for
  swift.org tarballs or alternative toolchain wrangling.
- **Passwordless sudo for the dev user is a hard preflight gate.** mpd
  needs it for resolved drop-in, ca-certificates, podman, etc.
  Preflight surfaces the bootstrap one-liner (`su -c "apt-get install
  -y sudo && install -m 440 /dev/stdin /etc/sudoers.d/$USER <<<
  '$USER ALL=(ALL) NOPASSWD:ALL'"`) as a user-only item if not
  already enabled.
- **No host-side anything.** No host CA mirror, no host route, no host
  resolver drop-in, no host trust import. The host runs the
  hypervisor; that's it.
- **Inside-VM trust** uses the snap-Firefox-aware path
  (`/etc/firefox/policies/{policies.json,mpd-rootCA.crt}`) — same fix
  we landed for ubuntu-kvm. mpd's `MachineActionSetup.installFirefoxPolicy`
  needs to switch to that path on Ubuntu (currently writes to the
  Debian Trixie firefox-esr distribution dir).
- **Static IP / cloud-init seed**: not needed. The user installs Ubuntu
  interactively; the VM's external IP is whatever the hypervisor
  hands out. Nobody on the host queries `https://*.mpd.test` from
  outside the VM, so no need to pin.

**provision.sh flow:**
1. Preflight: Ubuntu 26.04, passwordless sudo, required apt packages.
   Categorised report + `(a)` paste-recipe / `(b)` press-Enter
   affordance — same shape as ubuntu-kvm, smaller scope.
2. Apt install: `build-essential pkg-config make swiftlang git
   curl libnss3-tools qemu-guest-agent`.
3. `git clone` mpd into `~/Developer/mpd` if not present.
4. `make install` + `sudo ln -sf … /usr/local/bin/mpd`.
5. Write `~/Developer/mpd/conf/platform.env` with
   `MPD_PLATFORM=sandbox` (and no `MPD_CLIENT_OS` — the field is
   irrelevant when there's no separate client).
6. `mpd --setup`.

**Swift changes:**
- `mpd/Core/Platform.swift`: add `case sandbox = "sandbox"` to
  `PlatformKind`. Update validator error message + load-failure help
  text. Make `MPD_CLIENT_OS` optional / accept missing for sandbox
  (or default to the in-VM OS family).
- `mpd/Environment/Machine/MachineClientRecipe.swift`: skip the
  printed laptop recipes entirely when `platform == .sandbox`. (This
  block goes away in Phase 4 anyway; sandbox just gets there first.)
- `mpd/Environment/Certificate.swift` (or wherever `installFirefoxPolicy`
  lives): on Ubuntu, write to `/etc/firefox/policies/{policies.json,
  mpd-rootCA.crt}` rather than the firefox-esr distribution dir.

**Drop generic-vm** (after sandbox smoke-tests on a UTM-on-macOS
Ubuntu VM with snapshot):
- `rm -rf mpd-machine/platforms/generic-vm/`.
- Remove `case genericVM = "generic-vm"` from `PlatformKind`.
- `mpd-machine/platforms/README.md`: remove the generic-vm row, add
  the sandbox row.
- `docs/machine/{README,USAGE}.md`: replace generic-vm references
  with sandbox where appropriate; the "any other Linux / cloud /
  hand-rolled VM" row in `machine/README.md` either points at
  sandbox (if the user runs Ubuntu 26.04 in their VM) or notes that
  the prior generic-vm path is no longer maintained.
- `docs/ARCHITECTURE.md` §"Sister rule": drop the generic-vm bullet
  from the "doesn't apply" list (sandbox follows the inside-VM
  privilege rule from §"Mandatory privilege rule" — passwordless
  sudo per-command, run as the dev user).

**Test methodology:**
Build/test from inside an Ubuntu 26.04 VM in UTM on the Mac. Take a
hypervisor snapshot before each `provision.sh` run; revert after
each test cycle so we always start from a known-clean state.

**Definition of done:**
- `provision.sh` end-to-end on a clean Ubuntu 26.04 desktop install:
  preflight → apt → build → `mpd --setup` → snap-Firefox opens
  `https://mpd.test/` from inside the VM with no warning.
- Pre-warm of `php` runtime + `postgres:latest` runs successfully
  (sandbox flow doesn't strictly require it, but if we do it for
  ubuntu-kvm the symmetry is nice — this is a TODO to confirm during
  implementation).
- generic-vm directory + Swift case + doc references all gone.
- `mpd-machine/platforms/README.md` table reflects four platforms:
  macos-utm, ubuntu-kvm, windows-hyperv, sandbox.

## Phase 4 — Swift cleanup (Mac, after Phase 3 lands)

With generic-vm gone and the three automated platforms each handling
host-side configuration themselves, `MachineClientRecipe.swift`'s
"print laptop-side trust commands" surface area is dead weight.
Sandbox already gates it off (Phase 3); now delete it entirely.

**Files to touch:**
- `mpd/Environment/Machine/MachineClientRecipe.swift` — delete the
  macOS / Linux / Fedora trust-import + scp recipe blocks. Most of
  the file probably collapses to a one-line "see your platform's
  README" footer printed at the end of `mpd --setup`, or goes away
  entirely if nothing meaningful remains.
- `mpd/Environment/Machine/MachineActionSetup.swift` — remove the
  `Mpd.Environment.Integration.printClientArtifacts(...)` call near
  the end of setup if it becomes a no-op.
- `mpd/Core/Platform.swift` — once `MachineClientRecipe` no longer
  uses `MPD_CLIENT_OS`, evaluate whether the `ClientOS` enum still
  has any consumers worth keeping. If not, retire it.

**Definition of done:**
- `mpd --setup` prints no scp+trust recipes on any platform.
- `make install` succeeds on Mac and on Ubuntu 26.04 with no
  warnings (Swift 6.1 confirmed clean today).

## Phase 5 — Testing matrix (each platform host)

| Platform | Test | Expected |
|---|---|---|
| mpd-desktop (Mac) | wipe caroot/ on a Mac with an mpd-machine VM, run `mpd --setup` | desktop adopts CA from `~/.mpd-machine/ca/` |
| macos-utm | `setup.command` switch between two VMs; `uninstall.command` keep one VM | recipe affordance + per-VM works; CA mirror invariant holds |
| macos-utm | wipe `~/.mpd-machine/ca/` and run `setup.command` | restored from caroot/ |
| macos-utm | wipe caroot/ and run `setup.command` | restored from `~/.mpd-machine/ca/` |
| macos-utm | manually delete cert in Keychain Access; run `setup.command` | re-imported, no other state changes |
| windows-hyperv | full bootstrap on fresh Win 11 Pro VM (post-WSL refactor) | clean run; no PS encoding errors; trust via `\\wsl$\` |
| ubuntu-kvm | fresh Ubuntu 26.04 LTS host: preflight on a state-empty box → recipe (a) and (b) paths | both routes converge; libvirt group relogin gate triggers as documented |
| ubuntu-kvm | full bootstrap end-to-end → `https://mpd.test` from snap Firefox + Chromium | both browsers trust without warning |
| ubuntu-kvm | `setup.sh` second run on same host (existing VM) | re-verify path; silent if everything's in place |
| ubuntu-kvm | `stop.sh` → `start.sh` cycle | managedsave → resume; route re-asserted after host reboot |
| ubuntu-kvm | `uninstall.sh` keep one VM | host cleanup applied; kept VM intact; pool defined and dir preserved |
| ubuntu-kvm | `uninstall.sh` delete all VMs | host cleanup + pool destroy/undefine; pool dir left in place per design |
| sandbox | clean Ubuntu 26.04 LTS desktop install in UTM (snapshot taken) → `bash provision.sh` from inside the VM | preflight green, apt+build+`mpd --setup` complete, snap Firefox opens `https://mpd.test/` without warning, host stays untouched |
| sandbox | revert to snapshot, simulate "passwordless sudo not enabled" (skip the bootstrap one-liner) → re-run `provision.sh` | preflight refuses with the explicit `su -c …` recipe; second run after applying it passes through |
| sandbox | snap Firefox + Chromium both browse `https://mpd.test/` from inside the VM | both trust without warning |
| sandbox | `mpd create` / `mpd start` / `mpd stop` / `mpd --uninstall` from a GNOME terminal in the VM | full project lifecycle works without leaving the VM |

## Sequence (where each phase happens)

1. ~~Phase 1 — Ubuntu PC.~~ ✅ Done.
2. Reboot to Windows.
3. **Phase 2 — Windows host (windows-hyperv WSL refactor).**
4. Switch to Mac.
5. **Phase 3 — Mac, inside an Ubuntu 26.04 VM in UTM (sandbox + drop generic-vm).** Snapshot before each provisioning test; revert between cycles for a clean starting state.
6. **Phase 4 — Mac (Swift cleanup of `MachineClientRecipe`).**
7. **Phase 5 — every host in turn (full testing matrix).**
