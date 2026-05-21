# macOS + Parallels Desktop Pro bootstrap

Automation for `mpd-machine` on macOS using **Parallels Desktop Pro**.
For a "live in the VM" graphical alternative on any hypervisor
(including Parallels), see the
[sandbox platform](https://github.com/mutms/mpd/tree/main/setup/sandbox/README.md).

This directory targets developers who already own a Parallels Desktop
Pro license and want the laptop-driven workflow (host browser opens
`*.mpd.test` directly, host terminal SSHes into the VM). The VM itself
is provisioned from a Parallels template you build once and reuse.

## Files in this directory

| File | What it does |
|---|---|
| `setup.command` | Clone the template into a new mpd VM or switch the active VM (double-click). |
| `start.command` | Start the current VM. |
| `stop.command` | Suspend all mpd VMs (state preserved on disk; resumes instantly). |
| `uninstall.command` | Delete all mpd VMs and remove host networking. |

All four are double-clickable from Finder — macOS opens Terminal.app
automatically. Implementation lives under [`lib/`](lib/) (`*.sh` scripts —
no need to open them).

You can also invoke the underlying scripts directly from a Terminal:

```bash
bash setup/macos-prl/lib/setup.sh
```

## Prerequisites

- macOS host with **Parallels Desktop Pro** installed (`prlctl` available
  at `/usr/local/bin/prlctl`).
- An SSH key. `setup.command` will offer to generate one at
  `~/.ssh/id_ed25519` if missing.
- A prepared Parallels VM template named `mpd-machine-template` — see
  "VM template preparation" below.

`setup.command` may ask for your sudo password — but only if it actually
needs to change something (add the route to the container subnet, write
`/etc/resolver/mpd.test`, or import the mpd CA into the System keychain).
Before asking, it prints the exact runnable commands and gives you a
choice: open another Terminal and run them yourself, or press Enter and
let `setup.command` sudo for you. On a Mac that's already configured,
no password prompt happens at all.

Day-to-day `start.command` and `stop.command` rarely need sudo (only
`start.command` after a host reboot, to re-add the container subnet
route).

## VM template preparation

You build the template once, then `setup.command` clones it on demand.

1. **Configure Parallels Desktop Pro Shared network** to use
   `10.211.55.1–99` as its DHCP range. (Preferences → Network → Shared
   → "Provide IP addresses via DHCP" → set the upper bound to 99.) mpd
   VMs take static IPs from `.100+`, so they never collide with DHCP
   guests.
2. **Install Debian Trixie (13)** in a new Parallels VM using:
   - Hostname **`mpd-machine-base`**.
   - Software selection: Debian desktop environment, GNOME, SSH server,
     standard system utilities.
3. **Install Parallels Tools** in the VM. The graphical "Actions →
   Install Parallels Tools" path is the easy way; if it doesn't run,
   from a guest terminal:
   ```bash
   su -
   mount /media/cdrom -o exec
   bash /media/cdrom/installer/install-cli.sh -i
   ```
4. **Run the mpd sandbox take-over** inside that VM so it lands in the
   sandbox-ready shape. (Hostname must be `mpd-machine-sandbox` for the
   take-over's gate — rename, run the take-over, rename back to
   `mpd-machine-base` if you want.) This installs the runtime stack,
   builds `bin/mpd`, sets up the network stack, and ensures
   `authorized_keys` exists. See
   [setup/sandbox/README.md](../sandbox/README.md).
5. **Convert the VM to a template** in Parallels: File → Convert to
   Template. Name it `mpd-machine-template`.

After step 5 the template is reusable indefinitely. Rebuild it only
when you want a fresh base image (newer Debian point release, etc.).

## `setup.command` — clone the template or switch the active VM

Double-click `setup.command`. macOS opens Terminal and the script walks
you through:

1. Lists all existing `mpd-machine-NN` VMs in Parallels and marks the
   currently-active one (detected from the persistent route to the
   container subnet).
2. Asks for a VM number (`100–254`, since Parallels Shared DHCP owns
   `1–99`):
   - Enter an existing number to switch to that VM or re-verify it.
   - Enter a new number to clone the template into a new VM.

When cloning a new VM, the script asks for **username** (must exist in
the template), **memory in GB**, and **disk size in GB**, then **does
all host-side privileged work up front** so you can walk away through
the long unattended phase:

1. Prepares the mpd CA on the host — reuses
   `~/Developer/mpd/conf/caroot/{rootCA.pem,rootCA-key.pem}` if
   populated (shared with mpd-desktop and macos-utm), or
   `~/.mpd-machine/ca/` as a fallback, otherwise generates fresh.
2. Prints the exact commands it would run as root and lets you choose:
   copy/paste them into another terminal, or press Enter to let the
   script sudo for you. Either path ends at the same state.
3. Adds the route to `10.163.0.0/24`, writes `/etc/resolver/mpd.test`,
   imports the mpd CA into the System keychain, and drops cached sudo
   creds.
4. **Clones the template** via `prlctl clone mpd-machine-template
   --name mpd-machine-NN` (full clone — independent of the template's
   future lifecycle).
5. Sets memory, CPU, and disk size on the clone.
6. Starts the VM, discovers the DHCP-assigned IP via Parallels Tools,
   waits for SSH.
7. Renames the hostname, switches the active NetworkManager connection
   from DHCP to manual `10.211.55.NN/24`, restarts NetworkManager (SSH
   on the DHCP IP dies — by design).
8. Reconnects on the static IP, ensures the dev's SSH key is
   authorized, disables IPv6, pulls the repo to latest, rebuilds
   `bin/mpd`, uploads the host CA, runs `mpd --setup`.
9. **Pre-warms the demo stack** (PHP runtime + `postgres:latest`).
10. Adds a `Host mpd-machine-NN` block to `~/.ssh/config` (so
    `ssh mpd-machine-155` works) and writes
    `~/Desktop/mpd-machine.command`, which reads
    `~/.mpd-machine/current.env` at click time and SSHes to whichever
    VM is currently active. The block uses platform-agnostic markers
    — macos-utm and macos-prl share it, so switching between them
    just replaces the previous platform's entries cleanly.

The whole process takes 5–15 minutes depending on Parallels clone
speed and your Mac. After step 3 (the host-side privileged work) the
script holds no sudo creds; you can leave it running unattended.

When setup finishes:

- A `mpd-machine.command` shortcut appears on your desktop. Double-click
  it to open a Terminal session connected to the VM.
- `https://mpd.test` opens in Safari without HTTPS warnings.
- The shell greets you with a short welcome and a hint to run
  `demo moodle v5.2.0` for a one-command Moodle 5.2.0 site.

When switching to a different VM: the current VM is suspended in
Parallels, the selected VM starts (or resumes), and macOS networking is
updated to point to the new VM (route + CA).

## `start.command` / `stop.command`

`start.command` — starts the VM that is currently configured (detected
from the persistent route or `~/.mpd-machine/current.env`). Re-asserts
the route afterward (the route does not survive a host reboot). No
prompts.

`stop.command` — suspends all running mpd VMs via `prlctl suspend`.
Useful before shutting down the Mac. No prompts, no sudo.

## `uninstall.command`

Asks for confirmation (`Type YES`), then runs in order:

1. Removes host networking and trust — route to `10.163.0.0/24`,
   `/etc/resolver/mpd.test`, and any mpd CA certificate(s) in the
   System keychain. Same sudo affordance as `setup.command`.

   **CA preservation:** if `~/Developer/mpd/conf/caroot/rootCA.pem`
   still exists on disk, the keychain trust is **kept** (mpd-desktop
   and any future mpd-machine setup still depend on it). Delete that
   directory first if you want a true reset, then re-run `uninstall`.
2. Deletes `~/.mpd-machine/` (helper state — including the disposable
   CA mirror at `~/.mpd-machine/ca/`).
3. Removes the mpd-machine block from `~/.ssh/config`.
4. Removes `~/Desktop/mpd-machine.command`.
5. Asks `Delete <name>? [y/N]` for each `mpd-machine-NN` VM — default
   is keep. Only y'd VMs are stopped and deleted via `prlctl delete`.
   VM deletion is the last step on purpose: Ctrl-C during these
   prompts leaves the host fully cleaned up with the remaining VMs
   intact.

If you keep one or more VMs, host networking is still gone — re-run
`setup.command` and pick a kept VM's number to restore the route,
resolver, and (if needed) CA trust for it.

## Shared CA across mpd-desktop and mpd-machine VMs

`setup.command` keeps a single host CA alive in two real-file locations
and mirrors between them on every run:

- `~/Developer/mpd/conf/caroot/{rootCA.pem,rootCA-key.pem}` — the
  canonical mpd location, shared with mpd-desktop **and** macos-utm.
  Populated whenever `~/Developer/mpd/conf/` exists.
- `~/.mpd-machine/ca/{rootCA.pem,rootCA-key.pem}` — the disposable
  platform mirror. Always populated on any Mac that has run
  `setup.command` at least once. Deleted on uninstall.

Net effect: one CA per Mac, trusted once in the System keychain, shared
across mpd-desktop and every mpd-machine VM you create on this host.

If both copies somehow diverge, `~/Developer/mpd/conf/caroot/` wins as
the canonical source and the platform copy is overwritten, with a
warning printed.

CAs only flow host → VM, never the reverse. The System keychain only
ever trusts certificates generated on this Mac.

## Why the VM IP is pinned

`setup.command` writes an in-guest NetworkManager keyfile so the VM
boots with a static IP of `10.211.55.NN`. A static IP is required so
the host route + DNS resolver target a known address. mpd VMs are
constrained to `.100+` because Parallels Shared DHCP owns `.1–.99`.

The static IP is recorded in the VM at `~/Developer/mpd/conf/platform.env`
(`MPD_VM_IP=…`) and on the macOS host at `~/.mpd-machine/<vmname>.env`.

The active VM is tracked via the persistent route: `10.163.0.0/24`
(the container subnet) routes to the active VM's IP.

## Multiple VMs side-by-side

Run `setup.command` and enter a different octet to clone a second VM:

```
e.g. enter 156 alongside an existing 155 VM
```

Each VM gets its own static IP. Only one is "current" at a time. To
switch, run `setup.command` and enter the other VM's number — the
current VM is suspended and the selected VM resumes.

## Switching between VMs sharing an IP

If you delete a VM and clone a new one with the same octet,
`setup.command` clears stale `known_hosts` lines automatically. If you
SSH from another tool that caches keys independently:

```bash
ssh-keygen -R 10.211.55.155
```

## File transfer (host ↔ VM)

- **Parallels Shared Folder** — map a host directory into the VM via
  Parallels' Configuration UI. Convenient for project backups or
  anything bulky.
- **`scp/ssh` via fileaccess** — preferred for project backups. The
  `mpd-service-fileaccess` container exposes `/srv/backups/` as an
  SSH/scp endpoint at `fileaccess.service.mpd.test`.

Never print private keys to terminal output. Canonical secrets stay in
the VM's `~/Developer/mpd/conf/`.
