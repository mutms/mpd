# Proposal: `mpd-kvm` — Linux host binary for mpd-machine on libvirt/KVM

A Swift twin of `mpd-prl`, targeting Linux+libvirt instead of
macOS+Parallels. Same verb surface (`setup` / `doctor` / `uninstall`
/ `list` / `start` / `stop` / `ssh` / `clone`), same number-to-
clipboard sudo recipe UX, same tab completion.

**Cross-cutting design is owned by
[`host-binary-parallels.md`](host-binary-parallels.md)** — verb surface,
ArgumentParser contract, sudo-recipe printer, namespace tree, state file
layout. Implement `mpd-prl` first; this proposal is the diff against it.

## Goals

1. One executable on `$PATH`. `mpd-kvm <verb>` from any terminal.
2. Replace `setup/linux/lib/*.sh` (≈ 1500 lines) with the same Swift
   patterns used by `mpd-prl`.
3. Drop the bash twin of CA generation — reuse
   `Mpd.Environment.Certificate.generateCA` like `mpd-prl` does.
4. ArgumentParser-driven completion for verbs and dynamic VM names.

## Non-goals

- Generalizing to non-Ubuntu Linux distros in the initial cut. Today's
  bash hard-gates on Ubuntu 26.04 LTS; carry that forward unchanged.
  Distro-portability is a separate proposal.
- Replacing `mpd-prl` or `mpd-hpv`.

## Backend specifics

### `prlctl` → `virsh`

Swap `mpd-prl`'s `Mpd.PRL.Parallels` namespace (prlctl wrappers) for
`Mpd.KVM.Libvirt` inside the `mpd-kvm` target. Verb mapping:

| mpd-prl uses                 | mpd-kvm uses                              |
|------------------------------|-------------------------------------------|
| `prlctl list -a`             | `virsh list --all --uuid --name --state`  |
| `prlctl status <uuid>`       | `virsh domstate <uuid>`                   |
| `prlctl start <uuid>`        | `virsh start <uuid>`                      |
| `prlctl suspend <uuid>`      | `virsh suspend <uuid>` (or `managedsave`) |
| `prlctl stop <uuid> --kill`  | `virsh destroy <uuid>`                    |
| `prlctl clone <src> --name`  | `virt-clone --original <src> --name <new> --auto-clone` |
| `prlctl exec <uuid> <cmd>`   | n/a — use SSH or qemu-guest-agent         |

Guest IP discovery without polling Parallels Tools — libvirt's
`virsh net-dhcp-leases default` gives the active lease list; correlate
by MAC. Or read the DHCP lease file at
`/var/lib/libvirt/dnsmasq/default.status`.

UUID handling: libvirt's UUIDs are 36-char dashed (no braces), so no
brace-stripping step. Otherwise identical state-file shape to
`mpd-prl`'s.

### Static-IP pinning

`mpd-prl` writes a NetworkManager keyfile inside the guest (Debian
GNOME has NM). `mpd-kvm` does the same — the guest is also Debian
Trixie, also NetworkManager. Code path is identical; nothing to
generalize.

### Host-side networking (the bigger delta)

Linux host integration differs substantially from macOS. The Swift
abstraction is in `Mpd.KVM.Host` inside the mpd-kvm target. (Same
shape as `mpd-prl`'s `Mpd.PRL.Host`, duplicated rather than lifted —
see parallels proposal §"Swift namespace layout".) Per-OS deltas:

| Operation                  | macOS                                                | Linux                                                                  |
|----------------------------|------------------------------------------------------|------------------------------------------------------------------------|
| Add route                  | `route -n add -net 10.163.0.0/24 <vm-ip>`            | `ip route replace 10.163.0.0/24 via <vm-ip>`                           |
| Persistent route           | (not implemented — see parallels doc)                | `/etc/systemd/network/10-mpd.network` + `networkctl reload`            |
| Split DNS                  | `/etc/resolver/mpd.test` (mDNSResponder picks it up) | `/etc/systemd/resolved.conf.d/mpd.conf` + `systemctl reload systemd-resolved` |
| Trust the CA               | `security add-trusted-cert -d -r trustRoot -k …`     | `sudo cp <pem> /usr/local/share/ca-certificates/mpd-local.crt && sudo update-ca-certificates` |
| Firefox CA trust           | Firefox uses the system keychain on macOS            | Firefox enterprise policy at `/etc/firefox/policies/policies.json` + the CA cert side-by-side |
| Chromium CA trust          | Uses the system keychain                             | NSS DB at `~/.pki/nssdb` via `certutil -A` (libnss3-tools)             |

All of this is encoded in today's `setup/linux/lib/configure-client.sh`
and `setup/linux/lib/common.sh` — port that knowledge into Swift
methods under `Mpd.KVM.Host.Networking`.

### Clipboard helper

The shared sudo-recipe printer needs a Linux clipboard impl. Detect
at runtime:

- Wayland: `wl-copy` (Debian package `wl-clipboard`).
- X11: `xclip -selection clipboard` (Debian package `xclip`).
- Headless / neither available: skip the copy affordance, fall back
  to "press 'a' to run all via sudo" behavior.

### Swift toolchain

Already in use — `mpd` builds on Linux for the in-VM binary today.
The same `swiftlang` apt package the in-VM binary uses also builds
`mpd-kvm`. No new toolchain story.

### Privilege model

Linux `sudo` is per-command (same shape as macOS), so the
sudo-recipe printer ports directly. No UAC-style whole-binary
elevation needed.

### CA model — same simplification as `mpd-prl`

Today's `setup/linux/lib/common.sh` mirrors the CA between
`~/Developer/mpd/conf/caroot/` and `~/.mpd-machine/ca/` for the same
historical reasons as the macOS side. `mpd-kvm` drops the mirror and
makes `~/Developer/mpd/conf/caroot/` the only on-host location —
the repo is cloned on the Linux host (it's where `setup.sh` lives),
so caroot is always reachable.

Uninstall also follows the parallels model: never auto-touch the
system trust store; print `sudo update-ca-certificates --fresh` and
the Firefox-policy / NSS-DB cleanup lines as part of the
number-to-clipboard recipe; user picks which to run. Orphan certs are
name-constrained to `*.mpd.test`, harmless if left.

See `host-binary-parallels.md` §"CA model" for the full rationale.

## Build & Package.swift

Add to the `mpd-prl` shape:

```swift
.executableTarget(
    name: "mpd-kvm",
    dependencies: ["MpdCore"],
    path: "mpd-kvm",
    condition: .when(platforms: [.linux])
),
```

`make install` builds it on Linux hosts only; symlinks to
`/usr/local/bin/mpd-kvm` (sudo, or `~/.local/bin/mpd-kvm` if you'd
rather avoid that).

## Migration from bash

- `setup/linux/setup.sh` / `start.sh` / `stop.sh` / `uninstall.sh`
  (the top-level wrappers) become two-line shims: `exec mpd-kvm <verb>`.
- `setup/linux/lib/*.sh` deleted after the corresponding Swift verbs
  land.
- Today's `mpd-machine.desktop` launcher in GNOME Activities still
  points at the same shim; behavior unchanged from the user's POV.

## Testing

- Use libvirt's nested-VM support to smoke-test inside an existing
  KVM guest, OR run on a real Ubuntu+KVM host.
- Verify the apt-deps preflight (libvirt-daemon-system + friends)
  still fires before any VM ops.

## Open questions

- **Distro portability**. Today's bash strictly gates on Ubuntu
  26.04 LTS. Swift could relax that (detect apt vs. dnf vs. pacman,
  use protocol-shaped package-manager abstractions). But that's a
  meaningful new feature — propose separately if anyone wants it.
- **virsh user vs. system bus**. mpd today uses the system libvirt
  daemon (rootful). Could mpd-kvm support per-user `qemu:///session`?
  Maybe — but the host networking (route + resolver) needs root
  regardless, so the savings are smaller than they look.
- **virt-manager interop**. Users sometimes manage libvirt VMs via
  virt-manager GUI. mpd-kvm's VM picker should resolve current names
  via libvirt at display time (same as mpd-prl does via prlctl), so
  GUI renames stay visible.
