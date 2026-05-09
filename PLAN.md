# PLAN — platform parity for mpd-machine

Working doc. Delete when done.

Goal: get all four `mpd-machine` platforms (macos-utm, windows-hyperv,
ubuntu-kvm, generic-vm) onto the same shape — single host CA mirrored
across two real-file locations, sudo-recipe affordance, per-VM `[y/N]`
uninstall, host-only trust rule. Then prune dead Swift surface.

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
   never pull a CA off a VM into the host trust store. `generic-vm` is
   the explicit exception: the user manually copies if they want host
   trust (and accepts that they're trusting a VM-generated cert).
3. **Sudo recipe affordance.** Before any privileged operation: print
   the exact runnable commands; let the dev choose `(a)` run yourself
   in another terminal then press Enter, or `(b)` press Enter and let
   the script sudo. After the pause, re-detect; apply only what's
   still needed; drop cached creds with `sudo -k`. Reference:
   `macos-utm/lib/common.sh::print_sudo_recipe`.
4. **Per-VM `[y/N]` deletion in uninstall, as the last step.** Default
   keep. Ctrl-C during the loop leaves the host fully cleaned up and
   the remaining VMs intact.

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

## Phase 3 — `generic-vm` doc lift (any host)

Smallest change. Promote GNOME-in-VM to the primary path. Lift the
laptop-side trust recipes from `MachineClientRecipe.swift` into
`generic-vm/README.md` so Phase 4 doesn't orphan generic-vm users.

**Files to touch:**
- `mpd-machine/platforms/generic-vm/README.md` — add a "Laptop-side
  trust setup (optional, skip if you use GNOME-in-VM)" section with
  per-OS-family `scp` + trust commands (macOS / Debian-Ubuntu /
  Fedora-RHEL). Lead the bootstrap section with GNOME-in-VM as the
  recommended path; the laptop-trust path becomes the secondary
  branch.
- `docs/machine/USAGE.md:81` (the existing manual scp recipe) — link
  to `generic-vm/README.md` for the full per-OS guide instead of
  inlining.

**Definition of done:**
- generic-vm README has the per-OS laptop-trust section, self-contained.
- Phase 4 has a clean "delete from Swift" target.

## Phase 4 — Swift cleanup (Mac, after Phase 3 lands)

Remove now-redundant trust-import recipe blocks from
`mpd/Environment/Machine/MachineClientRecipe.swift`. Keep route + DNS
recipes (still useful for generic-vm users who don't read READMEs).

**Files to touch:**
- `mpd/Environment/Machine/MachineClientRecipe.swift` — delete the
  macOS / Linux / Fedora trust-import blocks. Update the printed
  footer to point at "see your platform's README for laptop-side
  trust setup."

**Definition of done:**
- `mpd --setup` no longer prints scp+trust recipes.
- `make install` succeeds on macOS.

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
| generic-vm | manual Debian Trixie netinst → `provision-vm.sh` → GNOME-in-VM browsing | no host trust needed |
| generic-vm | same VM, but with manual laptop-side scp+trust per README | host trust works on macOS / Linux laptop |

## Sequence (where each phase happens)

1. ~~Phase 1 — Ubuntu PC.~~ ✅ Done.
2. Reboot to Windows.
3. **Phase 2 — Windows host.**
4. Switch to Mac.
5. **Phase 3 — Mac (or any host — pure docs).**
6. **Phase 4 — Mac (Swift build).**
7. **Phase 5 — every host in turn.**
