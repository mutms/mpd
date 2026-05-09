# PLAN — platform parity for mpd-machine

Working doc. Delete when done.

Goal: get all four `mpd-machine` platforms (macos-utm, windows-hyperv,
ubuntu-kvm, generic-vm) onto the same shape — single host CA mirrored
across two real-file locations, sudo-recipe affordance, per-VM `[y/N]`
uninstall, host-only trust rule. Then prune dead Swift surface.

## Status

**Done (in `main`):**
- `macos-utm/lib/uninstall.sh` rewritten — sudo recipe for host cleanup,
  per-VM `[y/N]` deletion as the last step (Ctrl-C-safe), `-c "$CN" -t`
  cert deletion that handles admin-trust-settings'd certs and drains
  duplicates.
- `macos-utm/lib/configure-client.sh` rewritten — recipe affordance for
  route + resolver + CA; Phase-1 state snapshotted so Phase-3 reports
  stay accurate when the dev runs the recipe manually.
- `macos-utm/lib/common.sh` `prepare_host_ca` mirrors a single CA across
  `~/Developer/mpd/conf/caroot/` and `~/.mpd-machine/ca/`. New helper
  `copy_ca_files`. `HOST_CA_TEMP_DIR` / `cleanup_temp_ca` / dead
  `CA_CERT_REMOTE_PATH` removed. No more ephemeral / scratch-dir CAs.
- Swift: `DesktopActionSetup` adopts from `~/.mpd-machine/ca/` when
  caroot/ is missing. `Mpd.Environment.mpdMachineCARootDir` exposes the
  path (read-only from Swift).
- Docs updated: `ARCHITECTURE.md` §"Sister rule" item 6, the boundary
  rule (host-only trust), `machine/SECURITY.md`, `desktop/SECURITY.md`,
  `macos-utm/README.md`.

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

## Phase 1 — `ubuntu-kvm` (Ubuntu PC, current session)

Promote from "parked brief" to ships-grade. The existing
`mpd-machine/platforms/ubuntu-kvm/README.md` has the architecture
sketch — implement against it, but **layer in invariants 1 + 4** which
were written after the brief.

**Files to create** (under `mpd-machine/platforms/ubuntu-kvm/`):
```
setup.sh / start.sh / stop.sh / uninstall.sh   # entry shims
mpd-machine.desktop                            # GNOME launcher
lib/common.sh                                  # port + Linux-ize macos-utm
lib/setup.sh / start.sh / stop.sh / uninstall.sh
lib/create-vm.sh                               # direct qemu via systemd --user
lib/configure-client.sh
```

**Linux-isms:**
- VM driver: direct `qemu-system-{aarch64,x86_64}` as a systemd `--user`
  unit. Use libvirt's `virbr0` (default network) for the bridge — install
  `libvirt-daemon-system` purely for the bridge, don't drive VMs through
  libvirt. Pin the VM IP via cloud-init.
- Privileged ops:
  - `sudo ip route add 10.163.0.0/24 via <vm_ip>` (route)
  - `/etc/systemd/resolved.conf.d/mpd-test.conf` drop-in + `systemctl
    restart systemd-resolved` (resolver — `/etc/resolver/` doesn't
    exist on Linux)
  - `/usr/local/share/ca-certificates/mpd-test.crt` + `update-ca-certificates`
    (system trust)
  - Optional Firefox / Chromium NSS-DB import (`certutil -A`) — separate
    optional step, document but don't auto-do.
- State dir: `~/.mpd-machine/` (keep dotfile across all OSes for
  invariant 1 to read uniformly).
- CA: port `prepare_host_ca` + `copy_ca_files` verbatim from
  `macos-utm/lib/common.sh` — openssl is identical.

**Definition of done:**
- Fresh Ubuntu VM bootstrap end-to-end (incl. pre-warm of `php` runtime
  + `postgres:latest`).
- All four invariants exercised.
- README rewritten as user-facing docs (replace the parked brief).
- `mpd-machine/platforms/README.md` table: row flipped `Parked` →
  `Ships`.
- `docs/ROADMAP.md`: parked-bullet removed.
- `docs/machine/README.md` + `docs/machine/USAGE.md`: enumerate
  ubuntu-kvm alongside the other automated platforms.
- `docs/ARCHITECTURE.md` §"Sister rule": title generalized from
  "macos-utm bootstrap" to "macos-utm + ubuntu-kvm bootstrap".

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
| ubuntu-kvm | full bootstrap on fresh Ubuntu 24.04 LTS | clean run; optional NSS-DB import for Firefox/Chromium |
| generic-vm | manual Debian Trixie netinst → `provision-vm.sh` → GNOME-in-VM browsing | no host trust needed |
| generic-vm | same VM, but with manual laptop-side scp+trust per README | host trust works on macOS / Linux laptop |

## Sequence (where each phase happens)

1. **Phase 1 — Ubuntu PC (current SSH session, PHPStorm).**
2. Reboot to Windows.
3. **Phase 2 — Windows host.**
4. Switch to Mac.
5. **Phase 3 — Mac (or any host — pure docs).**
6. **Phase 4 — Mac (Swift build).**
7. **Phase 5 — every host in turn.**
