# Proposal: mpd as a nested-Podman container on Podman Desktop

**Status:** parked — feasibility-validated (WG+DNS path proven), no
implementation work scheduled.

## Motivation

mpd today ships in two deployment shapes — both involving a dedicated
Linux VM (sandbox or `mpd-virt`-driven managed VM). On macOS that means:

- Parallels VM, ~12 GB RAM allocated, separate snapshot/lifecycle
- Or libvirt/KVM on Linux hosts, or Hyper-V on Windows

For users who **already run Podman Desktop on macOS**, this is a second
VM running alongside Podman Desktop's own Linux VM. Two VMs, ~24 GB RAM,
duplicated kernel + duplicated init system, just to run mpd.

**The opportunity:** Podman Desktop's existing Linux VM already meets
every requirement mpd has for a host (Linux kernel, systemd, Podman,
namespaces, cgroups). If mpd ran inside a privileged container in that
VM — with its own nested Podman daemon — the second VM goes away.

## Background: mpd-desktop precedent

This is not a new idea. The killed `mpd-desktop` mode (removed in commit
`081c2b2`) ran mpd as a **native macOS binary** controlling Podman
Desktop's Podman machine via the standard `podman` CLI. A WireGuard
service container inside Podman Desktop's VM provided Mac-side
reachability of the `10.163.0.0/24` container subnet.

That worked. The networking model is proven: see
`docs/desktop/NETWORKING.md` and `mpd/Service/ServiceWireGuard.swift`
at commit `081c2b2~1` (both files deleted in the kill commit; reachable
via `git show 081c2b2~1:<path>`). The user has independently
re-validated WG+DNS into a Podman Desktop container in 2026.

The proposal here is **mpd-desktop's networking model + nested Podman**
— instead of mpd as a native macOS binary controlling the host Podman,
mpd lives **inside a privileged container** that runs its own Podman.
Everything mpd-managed (runtime containers, services, DBs) becomes a
child of that container. Delete the container, everything mpd-related is
gone in one operation.

## Architecture

```text
macOS host
  WireGuard client (utun)  10.164.0.1/32
    route 10.163.0.0/24 via tunnel
      |
      | UDP 127.0.0.1:51820
      v
Podman Desktop's outer machine (vanilla FCOS, libkrun or applehv)
  mpd-container  (--privileged, --systemd, debian:trixie)
    | wg0 endpoint 10.164.0.2/32, port 51820/udp
    | dnsmasq (resolves *.mpd.test inside)
    | systemd, podman daemon (nested), Swift mpd binary
    |
    +-- nested Podman containers (all on mpd-internal 10.163.0.0/24)
        mpd-service-dnsmasq    .3
        mpd-service-portal     .4
        mpd-service-fileaccess .5
        mpd-service-adminer    .6
        DBs                    .30–.99
        runtimes               .100+
```

Two key differences from mpd-desktop:

1. **mpd binary runs inside the container**, not on macOS. Same Linux
   binary the VM modes use today. No separate macOS build.
2. **Nested Podman**, not the outer Podman Desktop daemon. mpd-managed
   containers are children of `mpd-container`, not siblings of it.
   Delete `mpd-container` and all mpd state cleanly disappears.

### Outer machine — vanilla, isolated

The Podman Desktop machine that hosts `mpd-container` is **not modified
or replaced** — it's the standard machine Podman Desktop creates (the
official `quay.io/podman/machine-os` Fedora CoreOS image; custom machine
OS images are explicitly unsupported per the `podman machine init`
docs). mpd lives inside a container *on* that machine, not as the
machine itself.

To keep mpd state from intermingling with the user's other Podman work,
the setup orchestrator spins up a **dedicated podman machine for mpd**:

```bash
podman machine init mpd --cpus 4 --memory 8192 --disk-size 100
podman system connection default mpd-root
podman machine start mpd
```

Multiple machines coexist (Podman Desktop supports this natively); the
`mpd` machine is selectable in the GUI and via
`podman system connection default <name>`. Each machine is a separate
VM with its own container store, so cleanly isolated from
`podman-machine-default`.

**Provider choice** (`--provider`):

- **libkrun** — default on Apple Silicon. Passes the Mac GPU into the
  Linux machine. Pick this if AI workloads (containerized
  `llama.cpp`, etc.) inside the runtime containers should get GPU
  acceleration.
- **applehv** — Apple's Virtualization.framework. Default on Intel,
  available on Apple Silicon. Better filesharing/boot performance
  per the Podman 5.0 release notes; no GPU passthrough.
- **QEMU** — no longer a current macOS provider (deprecated/removed
  during the Podman 5 `podman machine` rewrite). Not a path forward.

The mpd code path is provider-agnostic — it sees a generic Linux host
inside the outer machine regardless of which virtualization backend is
underneath.

## Component breakdown

### `mpd-container` image (new)

Containerfile lives at `assets/podman-host/Containerfile` or similar.
Built from `debian:trixie` with:

- `systemd` (PID 1; requires `--systemd=always` at run time)
- `podman` + `crun` + `containers-common`
- `wireguard-tools` + `wireguard-go` (userspace WG — kernel module
  unavailable inside containers, but `wireguard-go` runs in userspace
  and `wg-quick` picks it up via `WG_QUICK_USERSPACE_IMPLEMENTATION`)
- `openssh-server` (so the Mac dev `ssh` into the container same way
  they SSH into a VM today)
- `git`, `curl`, `jq`, `dnsutils` — same dev-tools list as today's
  `runtime-base/bootstrap.sh` apt phase
- A pre-built `mpd` binary at `/opt/mpd/bin/mpd`, or the source
  checkout if the user wants live edits

Image build is one-shot (per mpd version). User pulls or rebuilds when
mpd updates.

### Run flags (sketch)

```bash
podman run -d --name mpd-container \
  --privileged \
  --systemd=always \
  --restart=always \
  --network=podman \
  -p 127.0.0.1:51820:51820/udp \
  -p 127.0.0.1:22:22 \
  -v mpd-opt:/opt/mpd \
  -v mpd-var-lib:/var/lib/mpd \
  -v mpd-containers:/var/lib/containers \
  -v mpd-srv:/srv \
  localhost/mpd-container:latest \
  /sbin/init
```

- `--privileged` required for nested Podman (cgroup delegation,
  network namespaces, mount operations).
- `mpd-containers` volume is critical: it's where the nested Podman
  stores its images and container layers. Without persistence,
  every `mpd-container` restart wipes runtime images.
- WG port (51820/udp) and SSH port (22) published to Mac localhost.
- `mpd-srv` mirrors the data volume contract from VM mode.

### WireGuard inside `mpd-container`

`wireguard-go` (userspace) instead of kernel module. `wg-quick@mpd0`
systemd unit, conf at `/var/lib/mpd/conf/wireguard/mpd0.conf` pushed in
by the new setup orchestrator (analogous to `mpd-virt`'s push for VM
mode). Existing `bootstrap/60-wireguard.sh` works unchanged once
`wireguard-go` is available.

### DNS

Same as mpd-desktop: a dnsmasq service container at `10.163.0.3` serves
`*.mpd.test`. macOS uses split DNS via `/etc/resolver/mpd.test ->
10.163.0.3` (delivered over the WG tunnel). The mpd-virt-style host
orchestrator handles the route + resolver + CA-trust setup on the Mac
(same operations, different invocation context).

### Nested Podman + systemd-in-systemd

The mpd binary today creates runtime containers with `--systemd=always`,
which requires the runtime daemon (Podman) to support systemd cgroups.
Inside `mpd-container`, that's nested. Podman handles this with
`--cgroup-manager=systemd` and `--cgroupns=host` flags on the *outer*
run, but in a fully privileged container the defaults usually work.
Specific incantation will need testing on Podman Desktop's specific
krun-backed VM.

## mpd binary code changes (estimated)

The migration to fixed FHS paths + the platform.env mode flag already
absorbed most of the multi-mode plumbing. Adding `podman-host` as a
third value of `MPD_PLATFORM` is small.

| Area | Change |
|---|---|
| `Mpd.VM.Platform.PlatformKind` | add `podmanHost = "podman-host"` |
| `Mpd.VM.installShutdownUnit` | check platform — inside a container, the systemd user unit still works, but verify there's no surprise (linger semantics differ in container PID 1) |
| `Mpd.VM.DNS.configureDNSResolver` | unchanged — systemd-resolved inside the mpd container works |
| `Mpd.VM.exec` (sudo paths) | unchanged — `--privileged` container has full sudo |
| `bootstrap/30-networking.sh` | hostname rename + IP pin may be no-ops or differently shaped (the container's IP is assigned by Podman Desktop's network, not by NM); detect platform and skip the static-IP block |
| `bootstrap/60-wireguard.sh` | one extra apt install: `wireguard-go`; set `WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go` env so `wg-quick` uses it |
| `Mpd.Runtime` container creates | unchanged — nested Podman accepts the same flags |

Rough estimate: 30–50 lines of Swift, mostly platform-branching, plus a
~10-line bash branch in `bootstrap/30` and `bootstrap/60`. No new
namespaces; the existing `Mpd.VM` layer covers the in-container shape
identically.

## New setup module: `setup/podman-host/`

Self-contained per the AGENTS.md `setup/` rule. Probably:

```
setup/podman-host/
├── README.md
├── setup.command              ← double-click on Mac to bring up mpd-container
├── lib/
│   ├── ensure-machine.sh      ← podman machine init mpd (if absent); set default
│   ├── build-image.sh         ← podman build (one-shot per mpd version)
│   ├── create-container.sh    ← podman run with the right flags
│   ├── push-wg-conf.sh        ← generate WG keys, push conf into container
│   ├── configure-mac-host.sh  ← Mac-side route + resolver + CA trust
│   │                            (mirrors mpd-virt-macos's Diag.swift)
│   └── common.sh
├── start.command  stop.command  uninstall.command
└── doctor.command
```

`ensure-machine.sh` runs first to set up the dedicated `mpd` machine
(or use an existing one). After that, all `podman` invocations from
this orchestrator target that machine's connection by default.

`mpd-virt-macos` becomes either irrelevant for this mode (the
podman-host mode doesn't drive a VM) or absorbs the new container
orchestration logic. Open question — see below.

## Lifecycle

| Operation | What it does |
|---|---|
| First-time setup | Build image; podman run; ssh in; run `mpd --setup` inside |
| Start | `podman start mpd-container` (already `--restart=always` for boot survival via Podman Desktop's machine start) |
| Stop | `podman stop mpd-container` — systemd inside catches SIGTERM, runs `mpd --stop`, graceful DB shutdown |
| Reset | `podman rm -fv mpd-container` then re-run setup. All mpd state gone in one operation. |
| Update mpd | rebuild image; rm container; recreate — or git pull inside the container + `make install` if mounted as live checkout |

## Differences vs current VM modes

**Same:**
- `mpd` binary, all sub-commands, all assets, runtime/project/DB model
- Mac UX (WG + DNS + CA trust, double-clickable setup)
- `https://*.mpd.test/` reachability from Mac browser
- SSH into runtimes (`ssh user@php.runtime.mpd.test`)

**Different:**
- One fewer VM. mpd state lives in volumes under Podman Desktop's VM
  instead of a dedicated Parallels/libvirt/Hyper-V VM
- Setup time ≈ minutes (image build + container start) vs ~15 min
  (template VM clone + bootstrap)
- Resource footprint: shares Podman Desktop's VM (typically 8 GB RAM
  allocated for the whole thing) instead of allocating fresh
- No hypervisor licensing (Parallels Pro) needed; just Podman Desktop
- macOS GPU passthrough story is whatever Podman Desktop provides
  (krun has limited GPU support today — this used to be mpd-desktop's
  primary draw)

## Open questions

1. **`wireguard-go` performance.** Userspace WG inside a Podman
   Desktop krun VM. Probably fine for dev traffic; benchmark before
   committing.
2. **Nested Podman storage driver.** Needs `vfs` or `fuse-overlayfs`
   when overlayfs-on-overlayfs isn't supported. Disk-space and
   performance implications.
3. **`--privileged` security posture.** This mode is for the dev's
   own machine — same trust assumption as mpd-virt today. Document
   it explicitly; not a security regression vs the existing modes
   (the dev's VM is also "trusted to do whatever").
4. **Mac-side orchestrator scope.** Does `mpd-virt-macos` grow a
   `podman-host` driver? Or does `setup/podman-host/` live entirely
   in mpd repo and skip mpd-virt-macos? Latter is simpler — Podman
   Desktop is the "hypervisor," no need for prlctl-style orchestration.
5. **Image distribution.** Pre-built on a registry, or `podman build`
   on first run from the cloned mpd repo? Pre-built is faster; from
   source matches the existing "git clone + make install" mental model.
6. **What lives in the container vs in volumes.** `/opt/mpd` could
   be a volume (live edits survive container rebuilds) or baked into
   the image (cleaner). `/var/lib/mpd` definitely a volume. `/srv`
   definitely a volume.

## Migration story

None. This is a fourth deployment mode (sandbox, managed-VM-via-mpd-virt,
plus the speculative linux/windows host-VM modes). Existing VM modes
stay; new mode is opt-in.

## Next concrete step (when work resumes)

Single-runtime end-to-end proof:

1. `podman machine init mpd --cpus 4 --memory 8192 --disk-size 100`
   then `podman system connection default mpd-root`. Confirm
   isolation from any existing `podman-machine-default`.
2. Write the `mpd-container` Containerfile (Debian Trixie + systemd
   + podman + wireguard-go + sshd + mpd binary).
3. `podman run --privileged --systemd=always ...` per the sketch
   above. SSH in.
4. `mpd --setup` — fix whatever breaks. The new `podman-host`
   platform kind branches out the few VM-specific assumptions
   (static-IP pin in bootstrap/30, kernel WG module in
   bootstrap/60).
5. `mpd --runtime-create=php` (nested Podman creates the child
   container).
6. `mpd create demo --git-repo=... --git-branch=...` →
   `mpd configure demo` → `mpd start demo`.
7. From Mac: WG up, `/etc/resolver/mpd.test` pointing at 10.163.0.3,
   `https://demo.mpd.test/` resolves and renders.

If that ladder works, the rest is rewriting the platform-branching
conditionals in mpd + finishing the `setup/podman-host/` orchestrator.
