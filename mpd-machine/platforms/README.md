# Bootstrap platforms

This directory holds platform-specific bootstrap material for
`mpd-machine` — scripts, assets, and READMEs that get a Debian Trixie
VM to the point where `mpd --setup` can run inside it. From there, the
mpd flow is identical regardless of which path you took to get the VM.

## Pick the path that matches your host

| Platform | Status | Path | What it gives you |
|---|---|---|---|
| **macOS + UTM** (Apple Silicon) | **Ships** | [`macos-utm/`](macos-utm/README.md) | One-shot `create-vm.sh`: downloads the Debian cloud image, prepares cloud-init, imports into UTM, builds `bin/mpd` inside the VM. End state: `mpd --setup` ready. |
| **Any Debian Trixie VM** (UTM, QEMU, libvirt/KVM, Hyper-V, VirtualBox, cloud, bare hardware sandbox) | **Ships** | [`generic-vm/`](generic-vm/README.md) | Manual five-step bootstrap from the official netinst ISO (`debian-13.4.0-{arm64,amd64}-netinst.iso`). Works anywhere a Debian VM does. |
| **Windows + Hyper-V** | **Ships** | [`windows-hyperv/`](windows-hyperv/README.txt) | Automated PowerShell bootstrap: `setup.cmd` downloads the Debian cloud image, provisions a Hyper-V Generation 2 VM with cloud-init, builds `bin/mpd` inside the VM, and configures Windows networking (route, NRPT DNS, CA certificate). |

## What "Ships" means

If a row is marked "Ships," its README is current, its scripts run, and
the path is a supported bootstrap. You should be able to land at
`mpd --setup` without surprises.

If a row is marked "Coming," the path described is what we're building
next. The fallback alternative (always `generic-vm/`) is what you use
in the meantime.

## What's not here

- **Cloud-provider-specific tooling** (Hetzner Cloud images, AWS AMIs,
  GCP, Azure) — none planned at the moment. The `generic-vm/` path
  works on any cloud Debian Trixie instance you provision yourself; if
  there's enough demand for one-shot cloud bootstrappers later, they'd
  land here as additional platform directories.
- **WSL2** — not the right shape. WSL2 is a partial Linux environment
  with surprising filesystem and networking semantics; mpd-machine
  expects a real, isolated VM. On Windows, use Hyper-V.
- **Docker Desktop / OrbStack as alternative backends** — `mpd-desktop`
  uses Podman Desktop specifically; `mpd-machine` uses rootful Podman
  inside a real VM. Other container backends aren't supported.

## Each platform directory is self-contained

**Hard rule:** every `platforms/<name>/` directory must run as a
standalone bundle. The intent is that any one of them can be released
as a small zip/tarball — a few `.sh` files for POSIX targets, a few
`.ps1` / `.cmd` for Windows targets, plus a README — and dropped on a
fresh host without the rest of the mpd repo.

What that means for the contents:

- A platform script may **only** reference files inside its own
  directory plus standard host tooling (`bash`, `curl`, `ssh`, `apt`,
  PowerShell, `gh`, etc.) and what it pulls down at runtime (`git
  clone <mpd-repo-url>` is fine; that brings the rest of the repo
  with it).
- Do **not** reach into a sibling `platforms/<other>/` directory, or
  into `mpd/`, `assets/`, `docs/`, `bin/`, etc. from a release-stage
  script. If two platforms need the same helper, duplicate it (small
  shells) rather than introducing a cross-directory dependency.
- The README inside each platform directory should be readable in
  isolation — assume the user has only the directory contents and
  can't see `docs/` or the rest of the repo.
- "Bootstrap" stage = before `git clone`. Once the script has cloned
  the repo to `~/Developer/mpd`, anything goes — that's mpd's normal
  build/setup flow, and the user has the full repo.

**Note for AI agents working in this repo:** when modifying or adding
files under `platforms/<name>/`, don't introduce relative paths
pointing outside that directory or symlinks into other parts of the
repo. Each platform must remain shippable as a flat archive of its own
contents.
