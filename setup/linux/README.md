# Ubuntu + KVM bootstrap

Automation for `mpd VM` on **Ubuntu 26.04 LTS** using
**libvirt + KVM**. For a "live in the VM" graphical alternative on
any hypervisor, see the [sandbox platform](../sandbox/README.md).

This directory ships polished, single-developer-laptop scripts that
mirror the macos flow — sudo recipe affordance, host-only CA
trust, per-VM `[y/N]` uninstall, no surprises during the long
unattended VM-creation phase.

## Files in this directory

| File | What it does |
|---|---|
| `setup.sh` | Create a new mpd VM or switch the active VM. |
| `start.sh` | Start the current VM. |
| `stop.sh` | Suspend all running mpd VMs (state saved to disk; resumes instantly via libvirt's managedsave). |
| `uninstall.sh` | Remove host networking + trust, then ask per-VM `[y/N]` whether to delete each VM. |

Implementation lives under [`lib/`](lib/) (`*.sh` scripts — no need to
open them).

Run from a terminal:

```bash
bash setup/linux/setup.sh
```

GNOME's Files (Nautilus 43+) doesn't double-click-launch executable
shell scripts by default, so we don't ship a Files-launchable shim
for setup. Once setup completes, a desktop launcher appears in
GNOME Activities (and on `~/Desktop/` when desktop icons are
enabled) for daily SSH access — that part *is* one-click.

## Prerequisites

- **Ubuntu 26.04 LTS** (Resolute Raccoon). The script refuses to run
  on other versions; older Ubuntu LTS releases work in concept but
  aren't tested. Try the [sandbox platform](../sandbox/README.md)
  if you'd rather work inside the VM directly.
- **Hardware virtualization enabled in BIOS/UEFI** (Intel VT-x /
  AMD-V). Preflight checks `/dev/kvm` and the CPU flag.
- **An SSH key**. `setup.sh` offers to generate `~/.ssh/id_ed25519`
  if missing.
- **One-time sudo** to install apt packages and set up the libvirt
  pool directory; preflight prints the exact commands and lets you
  paste-run them or press Enter to authorize.

## `setup.sh` — create a VM or switch the active VM

`setup.sh` runs in stages and is re-entrant — re-run after any
preflight failure and it picks up where it left off. Stages:

### 0. Pre-flight

Read-only checks:

- Ubuntu 26.04 (refuses other versions).
- `/dev/kvm` present + CPU `vmx`/`svm` flag.
- Required apt packages: `libvirt-daemon-system`, `libvirt-clients`,
  `qemu-system-x86`, `qemu-utils`, `cloud-image-utils`,
  `genisoimage`, `libnss3-tools`.
- Recommended (not auto-installed): `virt-manager` for a GUI VM list.
- User in the `libvirt` group, *active in the current shell* (not
  just listed in `/etc/group` — the script can't proceed if the
  group isn't effective yet).
- libvirt's `default` network running + autostart.
- VM-disk pool dir at `/var/lib/mpd-virt/$USER/` (root-owned
  parent, user-owned child).

Anything missing is reported in two buckets — "things only YOU can
do" (BIOS, log out / log in after a fresh group add) and "things
this script can do (with sudo)." The script then prints a paste-able
recipe and gives you a choice: `(a)` open another terminal and run
the recipe yourself, or `(b)` press Enter and let `setup.sh` sudo
for you. The recipe text includes the optional `virt-manager`
install line; option `(b)` only auto-installs the *required* parts.

If the script just added you to the `libvirt` group, it always exits
with "log out and log back in, then re-run setup.sh" — group
membership doesn't activate in the current shell, no matter what
route you took to get there.

### 1. SSH key

If neither `~/.ssh/id_ed25519` nor `~/.ssh/id_rsa` is present,
the script offers to generate `id_ed25519` (interactive, hit Enter
twice for empty passphrase).

### 2. VM selection

Lists every existing `mpd-NN` libvirt domain (with state)
and marks the currently-active one (detected from the persistent
host route to the container subnet). Prompts for a VM number:

- Enter an existing number to switch to that VM or re-verify it.
- Enter a new number to create a new VM end-to-end.

Default for a fresh host: `158`.

### 3. New VM creation (when the entered number doesn't exist yet)

Asks for username, memory (default 12 GB), disk (default 200 GB),
**does the host-side privileged work upfront** (host CA prep, route,
DNS resolver, system trust, Firefox policies, NSS DB), then runs
the long unattended phase:

1. Defines a libvirt storage pool at
   `/var/lib/mpd-virt/$USER/disks/` (user-owned, libvirtd-readable).
2. Downloads the Debian Trixie generic-cloud image (~250 MB,
   cached for reuse).
3. Converts the raw image to qcow2 in the pool, resizes to your
   chosen size (sparse).
4. Builds a cloud-init seed ISO (user, SSH key, static IP, hostname
   `mpd-NN`).
5. Defines the VM via `virsh define` (KVM-accelerated, virtio
   disk/net, virtio-balloon for memory reclaim, virtio-rng).
6. Boots, waits for SSH, waits for cloud-init to finish.
7. Verifies the root filesystem grew to your requested size.
8. `git clone`s the mpd repo, writes platform identity to
   `~/Developer/mpd/conf/platform.env`.
9. Detaches the cloud-init CD via `virsh change-media --eject` and
   restarts the VM.
10. In-VM provisioning over SSH: 4 GB swap, build dependencies
    (`build-essential`, `swiftlang`), `make install` of mpd, host CA
    upload, `mpd --setup` (which installs podman, services, trust
    within the VM, **and the user-level `mpd.service` systemd unit**
    that auto-starts mpd on boot and graceful-stops on shutdown via
    `EventMpdPreStop` hooks; linger is enabled so the unit fires
    headless).

### 4. Pre-warm

After VM creation, runs `mpd --runtime-create=php` and `mpd
--db-create=postgres:latest` over SSH so the user's first
`demo moodle v5.2.0` finishes in 2-3 minutes instead of 10+.
Best-effort — failures here just mean lazy provisioning at first
demo invocation.

### 5. State refresh

Writes the SSH config block (`Host mpd VM mpd-NN`),
records the active VM in `~/.mpd-virt/current.env`, and creates
the desktop launcher (`~/.local/share/applications/mpd VM.desktop`
plus `~/Desktop/mpd VM.desktop` if a Desktop dir exists, with
`gio set ... metadata::trusted true` so GNOME doesn't ask before
launching).

### Existing-VM paths (re-verify / switch)

When you enter a number that matches an existing VM, the script
takes one of two short paths:

- **Re-verify current**: ensures the VM is running, then re-runs
  the host configure-client step (route, resolver, trust). Silent
  if everything's already in place.
- **Switch**: confirms, suspends the current VM via `virsh
  managedsave`, starts the chosen one, waits for SSH, runs the
  configure-client step against the new IP. State refresh follows.

## `start.sh` / `stop.sh`

`start.sh` — starts the VM that's currently configured (detected
from the persistent route or `~/.mpd-virt/current.env`). If the
VM was suspended via `stop.sh`, libvirt's managedsave resumes it
in seconds rather than booting fresh. Re-asserts the host route to
the container subnet (the route doesn't survive a host reboot —
this is the only place it costs sudo on a warm system).

`stop.sh` — `virsh managedsave`s every running mpd VM. State is
serialized to disk; next `start.sh` resumes. Useful before
shutting down the host or switching VMs via `setup.sh`.

## `uninstall.sh`

Asks for confirmation (`Type YES`), then runs in order:

1. **Removes user-level CA trust** — `certutil -D -n mpd-rootCA -d
   sql:~/.pki/nssdb` (Chromium / Chrome / Edge).
2. **Removes host networking + trust via the sudo recipe affordance**
   — same `(a)` / `(b)` pattern as setup.sh. Drops:
   - persistent route to `10.163.0.0/24`
   - `/etc/systemd/resolved.conf.d/mpd-test.conf`
   - `/usr/local/share/ca-certificates/mpd-test.crt` (and reloads
     the system trust bundle)
   - `/etc/firefox/policies/policies.json` + `mpd-rootCA.crt`
3. Removes `~/.mpd-virt/` (state).
4. Removes the `Host mpd VM` block from `~/.ssh/config`.
5. Removes the desktop launcher from
   `~/.local/share/applications/` and `~/Desktop/`.
6. **Asks `Delete <name>? [y/N]` for each `mpd-NN` VM** —
   default keeps. Only y'd VMs are stopped (`virsh destroy`) and
   deleted (`virsh undefine --remove-all-storage`). VM deletion is
   the last step on purpose: Ctrl-C during these prompts leaves the
   host fully cleaned up with the remaining VMs intact.

If you delete every VM, the libvirt storage pool is also
undefined. The user-owned directory `/var/lib/mpd-virt/$USER/`
is left in place — `rm -rf` it yourself if you want a true reset.

If you keep one or more VMs, host networking is gone — re-run
`setup.sh` and pick a kept VM's number to restore the route,
resolver, and CA trust for it.

## Why the VM IP is pinned

`setup.sh` assigns a static IP to each VM (`192.168.122.NN`) via
cloud-init's `network-config` (matched by `driver: virtio_net` so
it works regardless of the kernel-assigned interface name). A
static IP is required because the bootstrap automation needs to
SSH into the VM before it's fully up — DHCP would give an unknown
address that the script can't predict.

The IP is recorded in `conf/platform.env` inside the VM
(`MPD_VM_IP=...`) and in `~/.mpd-virt/<vmname>.env` on the host.

The active VM is tracked via the persistent route: the kernel route
to `10.163.0.0/24` (the container subnet) points at the VM's IP, so
`start.sh` can detect the current VM after a host reboot.

## Multiple VMs side-by-side

Run `setup.sh` and enter a different octet to create a second VM:

```
e.g. enter 159 alongside an existing 158 VM
```

Each VM gets its own static IP and libvirt domain name. Only one
VM is "current" at a time (the one the container route points at).
To switch, run `setup.sh` and enter the other VM's number — the
current VM is `managedsave`d and the chosen one resumes.

mpd's internal "active machine" label always remains `mpd-machine`
regardless of the chosen octet (kept as a stable state-file
identifier), so per-machine state lives at
`~/.mpd/machines/mpd-machine/` inside each VM independently.

## A GUI list of VMs (`virt-manager`)

Optional. The preflight recipe includes `virt-manager` in its
printed text but doesn't install it via the auto-sudo path —
install it yourself if you want a GUI:

```bash
sudo apt-get install -y virt-manager
```

`virt-manager` connects to `qemu:///system` and shows every libvirt
VM (including the mpd ones), with consoles, performance graphs,
and snapshot management. Console access via `virsh console
mpd-NN` works without virt-manager too.

## File transfer (host ↔ VM)

Two options:

- **scp via the dev user** — `scp some.tar.gz mpd-158:~/` for
  ad-hoc transfers.
- **scp/ssh via fileaccess** — preferred for project backups. The
  `mpd-service-fileaccess` container exposes `/srv/backups/` as an
  SSH/scp endpoint at `fileaccess.service.mpd.test`.

Never print private keys to terminal output. Canonical secrets
stay in the VM's `~/Developer/mpd/conf/`.

## Recovery: lost SSH key

If you lose the laptop's private SSH key and can no longer log
into the VM:

1. **Easiest**: rebuild the VM. `uninstall.sh` keeps your kept VMs
   safe; just `virsh undefine --remove-all-storage mpd-158`
   then re-run `setup.sh`. Local-only state in the VM is lost
   (project sources, DBs, generated CA, fileaccess host keys); git
   remotes and laptop-side notes survive.

2. **Single-user-mode recovery via `virsh console`**:
   ```bash
   virsh -c qemu:///system console mpd-158
   ```
   Reboot the VM (`virsh reboot mpd-158` from another
   terminal). When the GRUB menu appears, press a key during the
   countdown to interrupt auto-boot. Highlight the default entry,
   press `e` to edit, append `init=/bin/bash` to the `linux ...`
   line, then Ctrl-X (or F10) to boot.

   You land in a root shell with no auth. The root filesystem is
   read-only:
   ```
   mount -o remount,rw /
   ```
   Replace the public key:
   ```
   vi /home/<your-user>/.ssh/authorized_keys
   ```
   `sync` and reboot (`exec /sbin/init` or `virsh reset
   mpd-158`).

## Switching between VMs sharing an IP

If you recreate a VM with the same octet (e.g. you delete `.158`
and create another `.158`), `setup.sh` clears stale `known_hosts`
lines automatically. If you SSH from another tool that caches keys
independently:

```bash
ssh-keygen -R 192.168.122.158
ssh-keygen -R mpd-158
```

## Shared CA story

`setup.sh` keeps a single host CA alive in two real-file locations
and mirrors between them on every run:

- `~/Developer/mpd/conf/caroot/{rootCA.pem,rootCA-key.pem}` — the
  canonical mpd location. Populated only when `~/Developer/mpd/conf/`
  already exists.
- `~/.mpd-virt/ca/{rootCA.pem,rootCA-key.pem}` — the platform
  copy. Always populated after the first `setup.sh` run.

Wipe either side and the next `setup.sh` restores from the other.
Delete the cert from the system trust store (or `~/.pki/nssdb` for
Chromium, or `/etc/firefox/policies/mpd-rootCA.crt` for Firefox)
and the next `setup.sh` re-imports — no manual recovery dance.

CAs flow host → VM only. Neither caroot nor `~/.mpd-virt/ca/` is
ever populated from a VM source. If somehow neither location is
populated when you run the existing-VM `setup.sh` path (e.g. you
imported a libvirt domain definition created on another host),
host networking is configured but CA import is skipped — copy a
`rootCA.pem`+`rootCA-key.pem` pair into either location yourself
and re-run.

`uninstall.sh` removes the System trust cert, the Firefox policy +
cert, the NSS DB entry, and `~/.mpd-virt/` — but leaves
`~/Developer/mpd/conf/caroot/` alone (mirrors mpd's own
"persisted, not removed by --uninstall" convention).
