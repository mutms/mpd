# Ubuntu + KVM bootstrap

> **Status: parked.** This is the planned third "ships polished" platform
> for `mpd-machine`. Until it lands, Ubuntu users should follow the
> [`generic-vm/`](../generic-vm/README.md) manual bootstrap — it works
> on any Linux host that can boot a Debian Trixie netinst ISO.

This document is a brief for whoever picks the work up next (likely
a future Claude session running on an Ubuntu host). It captures
intent, target shape, and the open technical questions, so the
implementer doesn't have to re-derive any of it.

## Goal

Bring Ubuntu + KVM to feature parity with `macos-utm/` and
`windows-hyperv/`:

- **One-click bootstrap.** Run `setup.sh` (or double-click a
  `.desktop` launcher), answer four prompts (octet, user, memory,
  disk), provide sudo password once, walk away. Come back to a
  primed VM.
- **Pre-warm.** Tail of bootstrap calls `mpd --runtime-create=php`
  and `mpd --db-create=postgres:latest` over SSH so the user's
  first `demo moodle v5.2.0` finishes in 2–3 minutes.
- **Lifecycle scripts.** `start.sh` / `stop.sh` / `uninstall.sh`
  symmetric with the other two platforms.
- **Desktop launcher.** `~/.local/share/applications/mpd-machine.desktop`
  that opens a terminal SSH'd into the active VM.

## Scope: Ubuntu only

Naming reflects that — `ubuntu-kvm`, not `linux-kvm`. Platform
self-containment (see [`../README.md`](../README.md)) means the
bundle hard-codes apt package names, systemd-resolved paths, and
`update-ca-certificates` semantics. Debian users in the same family
will mostly find it works, but we ship and test against Ubuntu LTS
specifically.

Other distros (Fedora, Arch, openSUSE) keep using `generic-vm/`. If
demand later justifies it, a `fedora-kvm` sibling is the natural
shape — same architecture, different package names + CA tooling
(`update-ca-trust` instead of `update-ca-certificates`,
`/etc/pki/ca-trust/source/anchors/` instead of
`/usr/local/share/ca-certificates/`).

## Reference: existing platforms

The implementer should read these in order:

1. [`../macos-utm/README.md`](../macos-utm/README.md) — closest UX
   parallel (host-first CA, fenced sudo, `.command` shims, lib/
   layout, recipe-or-sudo affordance). Most of the `setup.sh` shape
   transplants almost verbatim; the libvirt/QEMU substitutions are
   the only meaningful differences.
2. [`../windows-hyperv/README.txt`](../windows-hyperv/README.txt) —
   how the elevated-context platform handles the same operations
   (route + resolver-equivalent + CA trust); the `.cmd` /
   `lib/*.ps1` split.
3. [`../macos-utm/lib/common.sh`](../macos-utm/lib/common.sh) —
   helper layout (`step` / `ok` / `warn` / `die`, `prepare_host_ca`,
   `print_sudo_recipe`, fenced-sudo predicates `route_needs_update`
   / `apply_route` etc.). Most of these port directly to Linux —
   only the `apply_*` bodies differ.
4. [`../macos-utm/lib/create-vm.sh`](../macos-utm/lib/create-vm.sh) —
   the inside-VM provisioning sequence (cloud-init seed, repo
   clone, Swift install, `mpd --setup`, autostart unit, motd) is
   identical regardless of hypervisor.

## Proposed file layout

```
mpd-machine/platforms/ubuntu-kvm/
├── README.md                          # rewritten: real user docs
├── setup.sh                           # primary entry (run from terminal or via .desktop)
├── start.sh                           # start current VM
├── stop.sh                            # suspend running mpd VMs
├── uninstall.sh                       # delete VMs + clean state
├── mpd-machine.desktop                # GNOME/KDE app launcher template (installed by setup.sh)
└── lib/
    ├── common.sh                      # constants + helpers (port from macos-utm)
    ├── setup.sh                       # main flow
    ├── create-vm.sh                   # parameterized single-VM creation
    ├── configure-client.sh            # host networking (route, resolver, CA)
    ├── start.sh / stop.sh / uninstall.sh
```

State directory (matching the other platforms' naming): `~/mpd-machine/`
(undotted on Linux per general Linux convention, same as Windows).

## Architecture sketch

### Hypervisor + VM management

QEMU + KVM, driven directly. Two viable approaches:

- **Direct QEMU** (recommended for v1): shell out to
  `qemu-system-aarch64 -enable-kvm` (or x86_64 host). Manage the VM
  as a systemd `--user` service so it survives terminal exit and
  starts on login. No libvirt dependency, no virt-manager, no
  groups to join. Closest to how `macos-utm` drives UTM via
  AppleScript. Lifecycle ops shell out to the same systemd unit.
- **libvirt + virt-manager** (later iteration if we want a GUI VM
  list): `virt-install` for create, `virsh` for lifecycle. virt-
  manager shows the VM in its UI. Heavier deps (libvirt-daemon-system,
  virt-manager, qemu-system); user must be in the libvirt group.

Pick direct QEMU for the parked plan. Keep libvirt as a future
option if there's demand.

### Networking

This is the trickiest deviation from macos-utm. macOS has a
built-in vmnet shared bridge (`192.168.64.0/24`); Linux has nothing
equivalent out of the box. Three viable options:

1. **QEMU user-mode networking (slirp).** Default. Easy. Doesn't
   work for us — host can't reach VM by IP, only port forwards.
   Rules out our model where the host adds a route to
   `10.163.0.0/24` via the VM's bridge IP.
2. **TAP + bridge with manual scripting.** Create a tap device,
   attach to a bridge (`br0` or new `mpdbr0`), assign host an IP
   on that bridge, run dnsmasq for DHCP/DNS — or pin static IPs.
   Total control. Lots of code.
3. **libvirt's default network.** libvirt creates `virbr0`
   (192.168.122.0/24, NAT'd). VMs get reachable IPs. Simpler than
   building our own bridge, but requires libvirt installed even if
   we drive QEMU directly. The `default` network is well-trodden;
   ubuntu-server/desktop has it ready out of the box once
   `libvirt-daemon-system` is installed.

Recommendation: use libvirt's `default` network even if QEMU is
driven directly. Install `libvirt-daemon-system` purely for
`virbr0`. The mpd VM gets a DHCP IP on 192.168.122.0/24; we pin it
via libvirt's `<dhcp><host name=... ip=...>` static reservation, or
inject a static IP via cloud-init like the other platforms do.

### Privileged host ops

Same trio as macos-utm:

- **Route** to container subnet `10.163.0.0/24` via VM IP. Use
  `sudo ip route add 10.163.0.0/24 via <vm_ip>`. Not persistent
  across reboot — `start.sh` re-adds. (Matches macos-utm's
  trade-off; LaunchDaemon-equivalent on Linux would be a systemd
  service or `/etc/network/if-up.d/` script. Park as v2.)
- **DNS resolver** for `*.mpd.test`. Ubuntu uses systemd-resolved.
  Drop a file at `/etc/systemd/resolved.conf.d/mpd-test.conf`:
  ```ini
  [Resolve]
  DNS=10.163.0.3
  Domains=~mpd.test
  ```
  Then `sudo systemctl restart systemd-resolved`. Verify with
  `resolvectl query foo.mpd.test`. (`/etc/resolver/` doesn't exist
  on Linux; systemd-resolved's `Domains=~mpd.test` is the
  equivalent of macOS's per-domain resolver.)
- **CA trust.** Copy to `/usr/local/share/ca-certificates/mpd-test.crt`
  (must be `.crt` extension, not `.pem`), then
  `sudo update-ca-certificates`. This adds it to the system trust
  bundle. Browsers using NSS (Firefox, Chromium) **don't read this
  bundle by default**; they have their own NSS DB at `~/.mozilla/`
  and `~/.pki/nssdb/`. Need separate `certutil -A` calls. mpd's
  `MachineActionSetup.swift` already does the in-VM NSS DB import —
  for the *host*, this is host-Claude's problem to handle.
- **Host-first CA.** Same scheme as macos-utm: bash twin of
  `Mpd.Environment.Certificate.generateCA` (already in
  `macos-utm/lib/common.sh::generate_mpd_ca`) — port verbatim;
  openssl behaves the same on Linux. The reuse-or-generate decision
  + `~/Developer/mpd/conf/caroot/` placement is identical to
  macos-utm.

### Sudo strategy

Same fenced-sudo + print-recipe pattern as macos-utm. `setup.sh`
prepares the CA on host, prints the runnable commands (route +
resolved drop-in + ca-certificates + browser NSS imports), gives
the dev the choice (run yourself / let the script sudo), re-checks
afterward, applies what's missing, drops cached creds. EXIT trap as
backstop. See `docs/ARCHITECTURE.md` §"Sister rule: host-side fenced
sudo (macos-utm bootstrap)" — the rule already covers this and
should be retitled / generalized when ubuntu-kvm lands.

### Pre-warm

Identical to macos-utm/windows-hyperv:

```bash
ssh "${VM_USER}@${VM_IP}" 'mpd --runtime-create=php' || warn "PHP runtime pre-warm failed"
ssh "${VM_USER}@${VM_IP}" 'mpd --db-create=postgres:latest' || warn "postgres pre-warm failed"
```

### Desktop launcher

Mac uses `~/Desktop/mpd-machine.command`. Linux equivalent:

- Write `~/.local/share/applications/mpd-machine.desktop` with:
  ```ini
  [Desktop Entry]
  Type=Application
  Name=mpd-machine
  Comment=SSH into the active mpd-machine VM
  Exec=gnome-terminal -- ssh mpd-machine    # or x-terminal-emulator -e
  Terminal=false
  Icon=utilities-terminal
  Categories=Development;
  ```
- `update-desktop-database ~/.local/share/applications/` to register.
- Optional: `~/Desktop/mpd-machine.desktop` for users who have
  desktop-icon support enabled (newer GNOME hides them by default).

## Open questions for the implementer

1. **Single-host vs multi-distro.** Stay strictly Ubuntu, or
   accept Debian-family as a tested bonus? Affects test matrix.
2. **Target Ubuntu version.** 24.04 LTS minimum? 22.04 still
   common. If 22.04, watch for older systemd-resolved syntax.
3. **virtbr0 vs custom bridge.** libvirt's `default` network is
   easy. Custom bridge gives more control but doubles the script.
4. **Fix host-side route across reboots.** systemd-networkd unit?
   `/etc/network/interfaces` snippet? `ip route add` in `start.sh`?
   Pick the one that's least surprising.
5. **Browser NSS DBs.** Auto-import for Firefox + Chromium, or
   leave for the user to handle? mpd inside the VM does it for the
   in-VM browsers; host is a different question.
6. **Wayland vs X11 terminal launch.** `Exec=gnome-terminal --
   ssh` works on GNOME; `Exec=x-terminal-emulator -e ssh` is
   distro-neutral but has quoting quirks. Pick a fallback chain.

## When this lands

Update three places:

- `mpd-machine/platforms/README.md` — flip the table row from
  `Parked` to `Ships`, expand the "What it gives you" column.
- `docs/ROADMAP.md` — remove the `Parked` bullet pointing here.
- `docs/machine/README.md` and `docs/machine/USAGE.md` — add
  Ubuntu+KVM to the "Bootstrap" enumeration alongside the other
  two automated platforms.
- `docs/ARCHITECTURE.md` — generalize the
  "Sister rule: host-side fenced sudo (macos-utm bootstrap)"
  subsection to cover both macos-utm and ubuntu-kvm (Windows
  remains the exception under UAC).
