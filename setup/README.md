# mpd setup — bootstrap platforms

Each script under `setup/` is a self-contained, single-file bootstrap
that gets a VM to the point where `mpd --vm-setup` can run. From there,
the mpd flow is identical regardless of which path you took.

The brand for the VM-mode product is **mpd VM**; this directory
holds the scripts that get someone *into* an mpd VM. Day-to-day usage
once inside lives in [`docs/USAGE.md`](../docs/USAGE.md); architecture
detail in [`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md).

## Pick the path that matches your situation

If you're new and don't know which to pick — start with **sandbox**.

| Platform | Path | What it gives you                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
|---|---|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Sandbox** (any hypervisor — UTM, Parallels, Hyper-V, VirtualBox, VMware, virt-manager, …) | [`mpd-sandbox-setup.sh`](mpd-sandbox-setup.sh) | Install Debian Trixie with the GNOME desktop in your hypervisor, set the hostname to `mpd-<NNN>` (a 3-digit id in 100..254), snapshot, run the script inside the VM (wget one-liner in the top-level README). mpd lives entirely inside the VM; the host gets zero DNS/route/trust changes. The hypervisor owns VM lifecycle from its own GUI.                                                                                                                                                                                                         |
| **Managed VM from a macOS or Linux host** | [`mpd-virt`](https://github.com/mutms/mpd-virt) (separate repo) | CLI orchestrator. `create` provisions a VM (Parallels, UTM or Apple container on macOS; libvirt/KVM on Linux; a Proxmox clone from either); `adopt <NNN> [IP]` adopts any Debian Trixie VM prepared with [`mpd-prepare-adopt.sh`](mpd-prepare-adopt.sh). Drives the bootstrap pipeline over SSH and wires host reachability (mpd-proxy overlay or SOCKS, DNS resolver, CA trust). `mpd-virt remove` / `uninstall` un-adopt and tear the host side down. |

**Sandbox** is the lowest-friction path: one bash script, runs inside
the VM, no host configuration, works on any hypervisor that boots a
Debian Trixie desktop. `mpd-virt` reaches *into* a Debian Trixie VM
from your macOS or Linux host — pick it when you want your laptop's own
browser to resolve `*.mpd.test` directly.

## Prepare the guest: disable in-guest automatic updates

Applies to any Debian guest you **keep and reuse** — a sandbox VM, or a
template you clone from. Run these inside the guest, once, while
preparing it:

```bash
# Timer-driven updaters — these are what actually install behind your back.
sudo systemctl disable --now unattended-upgrades
sudo systemctl mask apt-daily.timer apt-daily-upgrade.timer

# GNOME Software: stop it downloading updates, and stop its background
# service autostarting at login. The app stays launchable by hand.
sudo install -d /etc/dconf/db/local.d/locks
printf 'user-db:user\nsystem-db:local\n' | sudo tee /etc/dconf/profile/user
printf '[org/gnome/software]\ndownload-updates=false\ndownload-updates-notify=false\n' \
    | sudo tee /etc/dconf/db/local.d/00-mpd-no-auto-updates
printf '/org/gnome/software/download-updates\n/org/gnome/software/download-updates-notify\n' \
    | sudo tee /etc/dconf/db/local.d/locks/mpd-no-auto-updates
sudo dconf update
mkdir -p ~/.config/autostart
{ cat /etc/xdg/autostart/org.gnome.Software.desktop; echo 'Hidden=true'; } \
    > ~/.config/autostart/org.gnome.Software.desktop
```

> **Do not `systemctl mask packagekit`.** It looks like the obvious
> lever and it is a trap. `packagekit.service` is `static` and
> D-Bus-activated (`/usr/share/dbus-1/services/org.freedesktop.PackageKit.service`)
> — it never starts on its own, only when something asks for it.
> Masking doesn't make those callers quiet, it makes them *fail*:
> GNOME Software, GNOME Settings, and the GStreamer codec-install
> prompt each surface
> `GDBus.Error:org.freedesktop.systemd1.UnitMasked: Unit
> packagekit.service is masked.` Leave PackageKit unmasked and remove
> the things that *schedule* it, as above.

Three different things take the dpkg lock out from under a bootstrap:

- **`unattended-upgrades`** runs on a timer and holds the lock the
  longest, because it actually installs.
- **`apt-daily.timer` / `apt-daily-upgrade.timer`** run `apt-get
  update` (and drive unattended-upgrades where it's installed).
- **`packagekitd`**, activated by GNOME Software's background service
  at login, grabs the lock just to *check* for updates — which lands
  exactly when a freshly cloned or freshly installed VM is being
  bootstrapped. Disabling that autostart is what removes it; masking
  PackageKit is not.

None of them breaks a bootstrap: `bootstrap/20-install-software.sh` wraps every
`apt-get` with `DPkg::Lock::Timeout=300` (override with
`MPD_APT_LOCK_TIMEOUT`) plus `Acquire::Retries=3`, so a competing job
stalls the run instead of failing it. Worth knowing that Debian's
built-in 120-second default applies to `apt`, not `apt-get` — which is
why the wrapper sets it explicitly.

The reason to turn them off anyway is determinism, not speed. Every
bootstrap runs `apt-get` itself, and a kept guest gets rebuilt when its
hypervisor tooling changes (new Parallels Tools, say) — so a guest that
*also* updates itself adds nondeterminism without adding currency, and
can pull in package versions the image was never tested with. Nothing
in mpd uses PackageKit — but parts of the GNOME desktop do, on demand,
which is why it stays unmasked and only its schedulers go away.

VMs `mpd-virt create` builds from a cloud image have no desktop, so
`packagekitd` never runs there — but the `apt-daily` timers and possibly
`unattended-upgrades` still are.

## What's not here

- **Cloud-provider-specific tooling** (Hetzner Cloud images, AWS AMIs,
  GCP, Azure) — none planned at the moment. The sandbox path on a
  cloud Debian instance with GNOME is the closest current option.
- **Windows hosts** — not planned, a dead end for this project. WSL2
  is not the right shape (a partial Linux environment with surprising
  filesystem and networking semantics; mpd VM expects a real, isolated
  VM), and a Hyper-V bootstrap once lived here and was removed with the
  Linux one when `mpd-virt` grew a Linux host side.
- **Docker Desktop / OrbStack as alternative backends** — mpd uses
  rootful Podman inside a real VM. Other container backends aren't
  supported.

## Each script is self-contained

**Hard rule:** every script under `setup/` is a *single* file, published
as a raw URL for `wget | bash` distribution, and must run on a fresh VM
with nothing else from this repo present:

- A script may **only** reference standard guest tooling (`bash`,
  `curl`, `wget`, `apt`, `systemctl`, …) and what it pulls down at
  runtime (`git clone <mpd-repo-url>` is fine; that brings the rest of
  the repo with it).
- Do **not** reach into `assets/`, `docs/`, `bin/`, `bootstrap/`, etc.
  from the pre-clone stage. If two scripts need the same helper,
  duplicate it (small shells) rather than introducing a dependency.
- "Bootstrap" stage = before `git clone`. Once the script has cloned
  the repo to `/opt/mpd`, anything goes — that's mpd's normal
  build/setup flow, and the user has the full repo.

`mpd-sandbox-setup.sh` takes a fresh desktop VM over;
`mpd-prepare-adopt.sh` (the pre-step for `mpd-virt adopt`) follows the
same single-file shape. There are no per-host-platform directories any
more: the host side is `mpd-virt`'s job, on macOS and Linux alike.

**Note for AI agents working in this repo:** keep these scripts
single-file — no relative paths into other parts of the repo, no
symlinks, no shared `lib/`.
