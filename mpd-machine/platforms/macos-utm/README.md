# macOS + UTM bootstrap

Automation for `mpd-machine` on macOS using **UTM with its QEMU backend**
(arm64). For the platform-agnostic manual bootstrap (any Debian Trixie VM
you've already created yourself), see the generic-vm platform at
https://github.com/mutms/mpd

This directory is the supported flavor for laptop-driven Moodle plugin
development on Apple Silicon. QEMU + SPICE gives clipboard sync, dynamic
display resize, and visible DHCP leases in UTM's GUI.

## Files in this directory

| File | What it does |
|---|---|
| `setup.command` | Create a new mpd VM or switch the active VM (double-click). |
| `start.command` | Start the current VM. |
| `stop.command` | Suspend all mpd VMs (state preserved on disk; resumes instantly). |
| `uninstall.command` | Delete all mpd VMs and remove host networking. |

All four are double-clickable from Finder — macOS opens Terminal.app
automatically. Implementation lives under [`lib/`](lib/) (`*.sh` scripts —
no need to open them).

You can also invoke the underlying scripts directly from a Terminal:

```bash
bash mpd-machine/platforms/macos-utm/lib/setup.sh
```

## Prerequisites

- Apple M1 or later processor.
- UTM installed (App Store or [direct download](https://mac.getutm.app/)).
- An SSH key. `setup.command` will offer to generate one at
  `~/.ssh/id_ed25519` if missing.

`setup.command` may ask for your sudo password — but only if it actually
needs to change something (add a route, write `/etc/resolver/mpd.test`,
or import the mpd CA into the System keychain). Before asking, the
script prints the exact runnable commands and gives you a choice: open
another Terminal and run them yourself (handy if you'd rather not
type your password into a script, or just want to see what's
happening), or press Enter and let `setup.command` sudo for you. On a
Mac that's already configured, no password prompt happens at all.

Day-to-day `start.command` and `stop.command` rarely need sudo (only
`start.command` after a host reboot, to re-add the route).

## `setup.command` — create a VM or switch the active VM

Double-click `setup.command`. macOS opens Terminal and the script
walks you through:

1. Lists all existing `mpd-machine-NN` VMs in UTM and marks the
   currently-active one (detected from the persistent route to the
   container subnet).
2. Asks for a VM number:
   - Enter an existing number to switch to that VM or re-verify it.
   - Enter a new number to create a new VM end-to-end.

When creating a new VM, the script asks for **username**, **memory in
GB**, and **disk size in GB** (matching the Windows + Hyper-V flow),
then **does all host-side privileged work up front** so you can walk
away through the long unattended phase:

1. Prepares the mpd CA on the host: reuses
   `~/Developer/mpd/conf/caroot/{rootCA.pem,rootCA-key.pem}` or
   `~/.mpd-machine/ca/{rootCA.pem,rootCA-key.pem}` if either is
   populated, otherwise generates a fresh CA. Whichever exists, the
   two locations end the run mirrored — see the
   "Shared CA across mpd-desktop and mpd-machine VMs" section below
   for the full mirror behavior.
2. Prints the exact `route` / `tee` / `security` commands it would run
   as root and lets you choose: copy/paste them into another terminal
   (and press Enter to continue), or press Enter to provide a
   password and let the script sudo for you. Either path ends at the
   same state.
3. Adds the route to `10.163.0.0/24`, writes `/etc/resolver/mpd.test`,
   imports the mpd CA into the System keychain, and drops cached
   sudo creds.
4. Downloads the Debian cloud image (~200 MB, cached for reuse).
5. Extracts and resizes the raw disk to your chosen size.
6. Prepares a cloud-init seed ISO (user, SSH key, static IP).
7. Creates a UTM QEMU VM (aarch64) with `virtio-balloon-pci,free-page-reporting=on`
   so macOS reclaims unused guest memory.
8. Boots the VM, uploads the host CA into it, waits for cloud-init,
   clones the mpd repository, installs Swift, builds `bin/mpd`, runs
   `mpd --setup` (which reuses the uploaded CA), and enables
   `mpd --start` on VM boot.
9. **Pre-warms the demo stack**: builds the PHP runtime image and
   creates a `postgres:latest` DB container inside the VM so your
   first `demo moodle v5.2.0` doesn't pay the build/pull cost.
10. Updates `~/.ssh/config` with a `Host mpd-machine` block and creates
    `~/Desktop/mpd-machine.command` for one-click SSH access.

The whole process takes 15–25 minutes depending on internet speed and
your Mac. After step 3 (the host-side privileged work) the script
holds no sudo creds; you can leave it running unattended.

When setup finishes:

- A `mpd-machine.command` shortcut appears on your desktop. Double-click
  it to open a Terminal session connected to the VM.
- `https://mpd.test` opens in Safari without HTTPS warnings (mpd portal,
  Adminer database UI, etc.).
- The shell greets you with a short welcome message and a hint to run
  `demo moodle v5.2.0` for a one-command Moodle 5.2.0 site (typically
  ready in 2–3 minutes thanks to the pre-warm).

When switching to a different VM:

1. The current VM is suspended in UTM (state preserved on disk; resumes
   in seconds).
2. The selected VM starts (or resumes from a previous suspension).
3. macOS networking is updated to point to the new VM (route + CA).

## `start.command` / `stop.command`

`start.command` — starts the VM that is currently configured (detected
from the persistent route or `~/.mpd-machine/current.env`). Re-asserts
the route afterward (the route does not survive a host reboot). No
prompts.

`stop.command` — suspends all running mpd VMs via UTM's "save state to
disk." Useful before shutting down the Mac or switching VMs via
`setup.command`. No prompts.

## `uninstall.command`

Asks for confirmation (`Type YES`), then runs in order:

1. Removes host networking and trust — route to `10.163.0.0/24`,
   `/etc/resolver/mpd.test`, and any mpd CA certificate(s) in the System
   keychain. Same sudo affordance as `setup.command`: prints the exact
   `route` / `rm` / `security delete-certificate` commands and lets you
   choose between running them yourself in another Terminal or pressing
   Enter and letting the script sudo for you. If everything is already
   clean, no password prompt happens.
2. Deletes `~/.mpd-machine/` (helper state).
3. Removes the `Host mpd-machine` block from `~/.ssh/config`.
4. Removes `~/Desktop/mpd-machine.command`.
5. Asks `Delete <name>? [y/N]` for each `mpd-machine-NN` VM — default is
   keep. Only y'd VMs are stopped and deleted (UTM moves bundles to Trash;
   empty it manually if you want the disk space back). VM deletion is the
   last step on purpose: Ctrl-C during these prompts leaves the host fully
   cleaned up with the remaining VMs intact.

If you keep one or more VMs, host networking is still gone — re-run
`setup.command` and pick a kept VM's number to restore the route, resolver,
and CA trust for it.

The host-side parts of step 1–4 are irreversible without re-running
`setup.command`. Kept VMs are unaffected.

## Shared CA across mpd-desktop and mpd-machine VMs

`setup.command` keeps a single host CA alive in two real-file locations
and mirrors between them on every run:

- `~/Developer/mpd/conf/caroot/{rootCA.pem,rootCA-key.pem}` — the canonical
  mpd location, shared with mpd-desktop. Populated only when
  `~/Developer/mpd/conf/` already exists (we never pre-create the repo
  path on a Mac that hasn't cloned mpd).
- `~/.mpd-machine/ca/{rootCA.pem,rootCA-key.pem}` — the platform-owned
  copy. Always populated on any Mac that has run `setup.command` at least
  once.

Net effect: one CA per Mac, trusted once in the System keychain, shared
across mpd-desktop and every mpd-machine VM you create here. The
redundant copy is the safety net — wipe either caroot directory (or
delete the cert from Keychain Access) and the next `setup.command`
restores from the other side and re-trusts the keychain entry. No
manual recovery, no broken trust.

If both copies somehow diverge (e.g. mpd-desktop regenerated its CA after
you'd already used a different one with mpd-machine), `~/Developer/mpd/conf/caroot/`
wins as the canonical source and the platform copy is overwritten, with
a warning printed.

CAs only flow host → VM, never the reverse. The System keychain only
ever trusts certificates generated on this Mac. If you import a VM
created on another Mac onto a host that has no CA in either location
yet, `setup.command` will configure the route and DNS resolver but skip
CA import — HTTPS will warn until you copy a host CA into `~/.mpd-machine/ca/`
or `~/Developer/mpd/conf/caroot/` yourself.

`uninstall.command` removes the keychain trust and `~/.mpd-machine/`
(including the platform copy of the CA), but leaves
`~/Developer/mpd/conf/caroot/` alone — same "persisted, not removed by
--uninstall" convention mpd itself uses, so mpd-desktop keeps working.
Wipe `caroot/` manually if you want a true reset.

## Why the VM IP is pinned

`setup.command` assigns a static IP to the VM (`192.168.64.<NN>`) via
cloud-init. A static IP is required because the bootstrap automation
needs to SSH into the VM before it is fully up — DHCP would give an
unknown address that the script cannot predict.

The static IP is recorded in the VM at `~/Developer/mpd/conf/platform.env`
(`MPD_VM_IP=...`) and on the macOS host at `~/.mpd-machine/<vmname>.env`.

The active VM is tracked via the persistent route: the route to
`10.163.0.0/24` (the container subnet) points to the VM's IP, so
`start.command` can detect the current VM after a host reboot.

## Multiple VMs side-by-side

Run `setup.command` and enter a different octet to create a second VM:

```
e.g. enter 159 alongside an existing 158 VM
```

Each VM gets its own static IP and UTM display name. Only one VM is
"current" at a time (the one the container route points to). To switch,
run `setup.command` and enter the other VM's number — the current VM is
suspended and the selected VM resumes.

mpd's internal "active machine" label always remains `mpd-machine`
regardless of the chosen octet, so per-machine state lives at
`~/.mpd/machines/mpd-machine/` inside each VM independently.

## File transfer (host ↔ VM)

For UTM specifically, two transfer paths beyond `scp`:

- **UTM shared folder** — map a host directory into the VM
  (Edit > Sharing). Convenient for project backups or anything bulky.
- **`scp/ssh` via fileaccess** — preferred for project backups. The
  `mpd-service-fileaccess` container exposes `/srv/backups/` as an
  SSH/scp endpoint at `fileaccess.service.mpd.test`.

Never print private keys to terminal output. Canonical secrets stay in
the VM's `~/Developer/mpd/conf/`.

## Recovery: lost SSH key

If you lose the laptop's private SSH key and can no longer log into the
VM, you can replace the public key from the UTM console using single-user
mode. The cloud-init defaults lock all passwords (`lock_passwd: true`,
`ssh_pwauth: false`) so a normal TTY login won't work — but GRUB itself
isn't password-protected, so booting straight to a root shell is open.

**One UTM-specific gotcha first:** `lib/create-vm.sh` doesn't attach a
graphical display device — the VM only has a serial console. By default
UTM may not route that to a usable window, so GRUB output and the TTY
are invisible. Switch the serial device to UTM's built-in terminal:

1. Stop the VM in UTM.
2. Right-click the VM > Edit > Devices, find the Serial / Console entry.
3. Change its mode (or "Output") to "Built-in Terminal". Save.
4. Start the VM — UTM opens a text terminal window where you can see
   GRUB and interact with the kernel console.

Then recover:

5. Reboot the VM. Press a key during the GRUB menu countdown to
   interrupt auto-boot.
6. Highlight the default entry, press `e` to edit, find the `linux ...`
   line, append `init=/bin/bash` to the end. Press Ctrl-X (or F10) to
   boot.
7. You land in a root shell with no auth. The root filesystem is mounted
   read-only, so:
   ```
   mount -o remount,rw /
   ```
8. Replace the public key:
   ```
   vi /home/<your-user>/.ssh/authorized_keys
   ```
9. `sync` and reboot (`exec /sbin/init` or power-cycle).

After recovery, switch the serial device back to its previous mode in
UTM; the built-in terminal is only needed when you want to interact with
GRUB or a TTY login.

**Faster alternative:** just rebuild the VM. `setup.command` is cheap,
and a fresh VM rules out whatever made the original hard to access.
Run it with a different octet (e.g. `.159` if the old one is `.158`)
as a side-by-side experiment first; if everything works, delete the
old VM in UTM. The cost is whatever local-only state was in the old
VM (project sources, DBs, generated CA, fileaccess host keys) — git
remotes and laptop-side notes survive.

## Switching between VMs sharing an IP

If you recreate a VM with the same octet (e.g. you delete `.158` and
create another `.158`), `setup.command` clears stale `known_hosts` lines
automatically. If you SSH from another tool that caches keys
independently, you may need:

```bash
ssh-keygen -R 192.168.64.158
```
