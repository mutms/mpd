# mpd VM — sandbox platform

Graphical sandbox: install Debian Trixie (13) with the GNOME desktop in
any hypervisor (UTM / Parallels / Hyper-V / VirtualBox / virt-manager /
VMware / etc.), take a hypervisor snapshot, run one script. mpd lives
entirely inside the VM; the host gets zero DNS / route / trust changes.

The hypervisor owns VM lifecycle (start / stop / snapshot / revert from
its own GUI); mpd inside owns project lifecycle (`mpd create / start /
stop / configure`).

## When to pick sandbox

- **Experiments and Linux testing.** Anything destructive — testing
  a Trixie upgrade path, trying a PPA, validating a one-off hack —
  goes here. Snapshot before, revert if it breaks.
- **Dogfooding mpd itself.** If you're editing the in-VM `mpd` Swift
  sources or the host-side `mpd-virt-macos` orchestrator, a sandbox
  VM is where you can break the whole setup safely. Real Mac stays
  pristine.
- **First-time evaluation.** Newcomers who want to see mpd work
  without touching their host. The "host stays untouched" promise
  is strict: zero DNS, route, or keychain changes outside the VM.
- **Hosts where mpd VM's matched-host bootstrap doesn't apply.**
  Fedora, Arch, NixOS, cloud VMs, ARM Linux desktops — anywhere a
  hypervisor can boot Debian Trixie. mpd's flow inside the VM is
  identical regardless of how you got there.

For *daily* Moodle plugin work on macOS, you probably want the
host-integrated [Parallels Desktop Pro mode](../macos/README.md)
instead, where your host browser/IDE see `*.mpd.test` directly.

## Files in this directory

| File | What it does |
|---|---|
| `take-over-sandbox-vm.sh` | Entry point. Hostname gate + disclaimer + sudo bootstrap + repo clone (if needed) + hand off to `lib/provision.sh`. |
| `lib/provision.sh` | The work: apt deps, `make install`, `mpd --setup`, optional pre-warm. |

## Pick a hypervisor

Any will do — Debian Trixie is well-supported everywhere — but if you
don't already have one installed, the free + native options per host
OS:

- **macOS (Apple Silicon)**: [UTM](https://mac.getutm.app/) — free,
  uses Apple's Virtualization.framework directly (no third-party kernel
  extensions). Parallels Desktop / VMware Fusion also work if you
  already own them.
- **Windows 11 Pro/Enterprise**: Hyper-V — built in, enable via
  "Turn Windows features on or off."
- **Linux**: virt-manager + KVM — built into most distros
  (`apt install virt-manager` on Debian/Ubuntu).
- **Anywhere else**: VirtualBox (free, cross-platform).

## Prerequisites

- A clean **Debian Trixie (13)** install in your hypervisor of choice,
  with the **GNOME desktop task selected** during install (`tasksel`
  → "Debian desktop environment" + "GNOME"). The desktop is required —
  sandbox is the "live inside the VM" mode and needs Firefox, a
  terminal, and the GNOME launcher integration.
- VM sizing: **8 GB RAM, 4 CPUs, 100 GB disk** is the comfortable
  default. **4 GB / 2 CPUs / 50 GB** is the workable minimum (slow
  builds, tighter disk). The disk is sparse on most hypervisors —
  100 GB is what it can grow to, not what it allocates up front.
- Hostname **`mpd-sandbox`**. Easiest is to type that name into
  the hostname field during the Debian installer. If you already
  installed with a different hostname, rename now:
  ```bash
  sudo hostnamectl set-hostname mpd-sandbox
  sudo sed -i 's/^127\.0\.1\.1.*/127.0.1.1\tmpd-sandbox/' /etc/hosts
  # log out / log back in so your shell prompt picks up the new name
  ```
  The hostname is the safety gate — `take-over-sandbox-vm.sh` refuses
  any other hostname. Renaming the VM is a deliberate consent step,
  much harder to do by accident than typing a confirmation word.

  Some hypervisors (Parallels Desktop, for example) re-sync the guest
  hostname to the VM name in their UI. The gate only fires at the
  moment `take-over-sandbox-vm.sh` runs — drift after that is
  cosmetic and not enforced.
- An SSH or terminal session into the VM. Either works: a manually
  added authorized key (`ssh-copy-id user@<vm>`) or whatever
  guest-tools auto-injection your hypervisor provides (Parallels'
  shared SSH key, for example). The take-over script does not touch
  `~/.ssh/authorized_keys` either way.
- **A hypervisor snapshot taken before running the take-over script.**
  The script is destructive on purpose (passwordless sudo, system-wide
  CA trust, generated secrets, network-stack reconfiguration). If
  anything goes wrong, your only rollback is the snapshot.

## Run it

Inside the VM, one-shot via `wget` (preinstalled on Debian's standard
task; `curl` is not — it's `Priority: optional` on Debian, so a stock
install doesn't have it):

```bash
bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/setup/sandbox/take-over-sandbox-vm.sh)
```

…or, if the repo is already cloned:

```bash
bash /opt/mpd/setup/sandbox/take-over-sandbox-vm.sh
```

In standalone mode (no repo present), the script self-bootstraps:
`apt install git`, clones `https://github.com/mutms/mpd.git` to
`/opt/mpd/`, then hands off to `lib/provision.sh` from the
freshly cloned tree.

If you've installed `curl` yourself, the equivalent invocation also
works: `bash <(curl -sSL <url>)`.

## What it does

1. Hostname gate — must be `mpd-sandbox`.
2. OS gate — must be Debian Trixie (13).
3. Disclaimer + Enter-to-proceed.
4. Enables passwordless sudo (one-time password prompt for the install).
5. apt-installs `git` if missing; clones the repo if missing.
6. apt-installs `build-essential pkg-config make swiftlang libnss3-tools qemu-guest-agent`.
7. Standardizes the network stack: writes
   `/etc/NetworkManager/conf.d/10-mpd-dns.conf` with
   `dns=systemd-resolved`, apt-installs `systemd-resolved` +
   `libnss-resolve`, and restarts NetworkManager. mpd VM expects
   systemd-resolved as the host DNS sink across every supported
   install profile.
8. Adds Microsoft's apt repo and installs **VS Code** so the in-VM
   IDE story works without leaving the desktop.
9. `make install` of mpd; bin/ is added to PATH via ~/.bashrc.
10. Writes `/var/lib/mpd/conf/platform.env` with `MPD_PLATFORM=sandbox`.
11. `mpd --setup` — generates the CA, installs system trust + Firefox
    policies + `~/.pki/nssdb` import, brings up podman + dnsmasq + portal
    + adminer + fileaccess.
12. Best-effort pre-warm: `mpd --runtime-create=php` and
    `mpd --db-create=postgres:latest`.
13. Drops GNOME launchers (`~/.local/share/applications/mpd.desktop` for
    `mpd --tui`, plus a desktop-icon copy of VS Code's launcher when
    desktop icons are on) so the user has both an mpd icon and a
    VS Code icon ready to click.

## Optional: GNOME tweaks for macOS users

GNOME 48's default "Dash" hides at the bottom of the Activities
overview — discoverable on Super-press, but invisible the rest of the
time, which feels alien if you're coming from a macOS dock. Two
optional add-ons make the desktop noticeably closer to Mac muscle
memory; both are user-scoped, no `mpd --setup` interaction.

```bash
# Extension Manager GUI — browse / install / configure GNOME Shell
# extensions, including everything below.
sudo apt install -y gnome-shell-extension-manager
extension-manager   # launches the GUI

# Dash to Dock (apt-shipped build, ready immediately after a logout).
sudo apt install -y gnome-shell-extension-dashtodock
# …then log out / log back in (Wayland can't hot-reload extensions),
# then enable + pin to the bottom:
gnome-extensions enable dash-to-dock@micxgx.gmail.com
gsettings set org.gnome.shell.extensions.dash-to-dock dock-position BOTTOM
gsettings set org.gnome.shell.extensions.dash-to-dock dock-fixed true
gsettings set org.gnome.shell.extensions.dash-to-dock autohide false
gsettings set org.gnome.shell.extensions.dash-to-dock intellihide false
gsettings set org.gnome.shell.extensions.dash-to-dock extend-height false
```

A couple of extra `gsettings` knobs that lean further into Mac-feel:

```bash
# Hot corner top-left → Activities (≈ macOS Mission Control corner).
gsettings set org.gnome.desktop.interface enable-hot-corners true

# Click an app icon to minimize its window (macOS dock click-to-hide).
gsettings set org.gnome.shell.extensions.dash-to-dock click-action 'minimize'
```

This is purely cosmetic — the mpd flow works fine with or without it.
If you want to undo everything: `sudo apt purge gnome-shell-extension-dashtodock`
and the gsettings keys reset to defaults next session.

## Reverting

`take-over-sandbox-vm.sh` is destructive on purpose. The only supported
rollback is reverting your hypervisor snapshot.

There is **no** `uninstall.sh` shim in this directory: VM lifecycle
(start / stop / snapshot / revert / delete) is the hypervisor's job.
For a partial cleanup of mpd's runtime state without a full snapshot
revert, manually remove containers and state:

```bash
podman ps -a --format '{{.Names}}' | grep -E '^mpd-' | xargs -r sudo podman rm -f
sudo podman network rm mpd-internal 2>/dev/null || true
sudo podman volume rm mpd-data-volume 2>/dev/null || true
sudo rm -rf /var/lib/mpd/state /var/lib/mpd/env
# keep /var/lib/mpd/conf/ if you want to reuse the same CA on re-setup
```

(There is no `mpd --uninstall` verb today. A reset/uninstall verb
is on the roadmap.)

## Day-to-day

Once setup completes, mpd commands work identically to other
mpd VM platforms — see
[`docs/USAGE.md`](../../docs/USAGE.md).
