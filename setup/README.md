# mpd setup — bootstrap platforms

Each subdirectory under `setup/` is a self-contained bootstrap that
gets a VM to the point where
`mpd --setup` can run. From there, the mpd flow is identical
regardless of which path you took.

The brand for the VM-mode product is **mpd VM**; this directory
holds the scripts that get someone *into* an mpd VM. Day-to-day usage
once inside lives in [`docs/USAGE.md`](../docs/USAGE.md); architecture
detail in [`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md).

## Pick the path that matches your situation

If you're new and don't know which to pick — start with **sandbox**.

| Platform | Path | What it gives you |
|---|---|---|
| **Sandbox** (any hypervisor — UTM, Parallels, Hyper-V, VirtualBox, VMware, virt-manager, …) | [`sandbox/`](sandbox/README.md) | Install Debian Trixie with the GNOME desktop in your hypervisor, set the hostname to `mpd-sandbox`, snapshot, run `take-over-sandbox-vm.sh`. mpd lives entirely inside the VM; the host gets zero DNS/route/trust changes. The hypervisor owns VM lifecycle from its own GUI. |
| **macOS + Parallels / UTM** | [`mpd-virt-macos`](https://github.com/mutms/mpd-virt-macos) (separate repo) | Swift CLI orchestrator (`mpd-virt`). `clone` against a Parallels template VM, or `create` against UTM via cloud-init. Drives the bootstrap pipeline over SSH and applies macOS networking (route, DNS resolver, CA trust). `mpd-virt diag` re-applies host config after a reboot; `mpd-virt delete` / `uninstall` tear everything down. |
| **Ubuntu + KVM** (Linux desktop) | [`linux/`](linux/README.md) | `bash setup.sh` from a terminal: preflight (KVM, libvirt-daemon-system + friends, libvirt group, libvirt default network, `/var/lib/mpd-virt/$USER/`) with the same `(a)` run-yourself / `(b)` press-Enter sudo recipe affordance as macos; libvirt-driven VM creation against the default `virbr0` network with cloud-init for static IP; host configuration (`ip route` + systemd-resolved drop-in + `update-ca-certificates` + Firefox policies + `~/.pki/nssdb`); pre-warm + `mpd VM.desktop` launcher in GNOME Activities. Ubuntu 26.04 LTS only. |
| **Windows + Hyper-V** | [`windows/`](windows/README.txt) | PowerShell bootstrap: `setup.cmd` downloads the Debian cloud image, provisions a Hyper-V Generation 2 VM with cloud-init, builds `bin/mpd` inside the VM, and configures Windows networking (route, NRPT DNS, CA certificate). |

**Sandbox** is the lowest-friction path: one bash script, runs inside
the VM, no host configuration, works on any hypervisor that boots a
Debian Trixie desktop. The other three platforms reach *into* a
Debian Trixie VM from a matched host (macOS / Ubuntu / Windows
respectively) — pick one of those when you want your laptop's own
browser to resolve `*.mpd.test` directly.

## What's not here

- **Cloud-provider-specific tooling** (Hetzner Cloud images, AWS AMIs,
  GCP, Azure) — none planned at the moment. The sandbox path on a
  cloud Debian instance with GNOME is the closest current option.
- **WSL2** — not the right shape. WSL2 is a partial Linux environment
  with surprising filesystem and networking semantics; mpd VM
  expects a real, isolated VM. On Windows, use Hyper-V.
- **Docker Desktop / OrbStack as alternative backends** — mpd uses
  rootful Podman inside a real VM. Other container backends aren't
  supported.

## Each platform directory is self-contained

**Hard rule:** every `setup/<name>/` directory must run as a standalone
bundle. The intent is that any one of them can be released as a small
zip/tarball — a few `.sh` files for POSIX targets, a few `.ps1` /
`.cmd` for Windows targets, plus a README — and dropped on a fresh
host without the rest of the mpd repo.

What that means for the contents:

- A platform script may **only** reference files inside its own
  directory plus standard host tooling (`bash`, `curl`, `ssh`, `apt`,
  PowerShell, `gh`, etc.) and what it pulls down at runtime (`git
  clone <mpd-repo-url>` is fine; that brings the rest of the repo
  with it).
- Do **not** reach into a sibling `setup/<other>/` directory, or into
  `mpd/`, `assets/`, `docs/`, `bin/`, etc. from a release-stage
  script. If two platforms need the same helper, duplicate it (small
  shells) rather than introducing a cross-directory dependency.
- The README inside each platform directory should be readable in
  isolation — assume the user has only the directory contents and
  can't see `docs/` or the rest of the repo.
- "Bootstrap" stage = before `git clone`. Once the script has cloned
  the repo to `/opt/mpd`, anything goes — that's mpd's normal
  build/setup flow, and the user has the full repo.

The sandbox platform is the natural exception that proves the rule:
its `take-over-sandbox-vm.sh` is a *single* file that's also published
as a raw URL for `curl | bash` distribution, so it doesn't need a zip
bundle at all.

**Note for AI agents working in this repo:** when modifying or adding
files under `setup/<name>/`, don't introduce relative paths pointing
outside that directory or symlinks into other parts of the repo. Each
platform must remain shippable as a flat archive of its own contents.
