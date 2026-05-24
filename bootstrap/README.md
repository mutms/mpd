# `bootstrap/` — bring a Debian Trixie VM to the state `mpd --setup` expects

These scripts are the single source of truth for VM-side bring-up. The
**template VM stays pure Debian** — bootstrap runs in full on every
sandbox/managed VM that gets created.

There is **no orchestrator** (no `run-all.sh`). Each step is independently
invokable; callers list them explicitly.

## Steps

| File | Wgettable? | Interactive? | What it does |
|---|---|---|---|
| `10-passwordless-sudo.sh` | yes | yes (one root password prompt) | Validate hostname (`mpd-template`, `mpd-sandbox`, `mpd-template-<suffix>`, `mpd-sandbox-<suffix>`, or `mpd-NNN`) + Debian Trixie. If `sudo -n` already works, no-op. Otherwise write `/etc/sudoers.d/00-mpd-<user>` via `su -c`. |
| `20-git-clone.sh` | yes | no | Assert `sudo -n` works; create `/opt/mpd` + `/var/lib/mpd` (owned by the dev user); apt-install `git` + `ca-certificates`; clone (or fast-forward) the mpd repo to `/opt/mpd`. No hostname gate — step 10 already did it. |
| `30-networking.sh` | no (local) | no | Hostname rename to `mpd-<NNN>`, NetworkManager + systemd-resolved + libnss-resolve, optional static IP for octets in `[100, 254]`, IPv6 disable, write `/var/lib/mpd/conf/platform.env`. |
| `40-install-software.sh` | no (local) | no | apt-install the full runtime + build + diagnostics package set; enable `podman-restart.service`. |
| `70-update.sh` | no (local) | no | **Out-of-band**: not part of the initial 10..60 chain. Run by `mpd-virt update <NNN>` (or by hand) to refresh a running VM: pulls latest source, rebuilds `mpd`, re-runs `mpd --setup`. Idempotent. **Caveat**: when a release changes 70-update.sh's own orchestration (adds a new step, reorders them), the running process is still the pre-pull copy — run update twice, or use the `exec` self-reexec pattern documented at the top of `70-update.sh`. |
| `50-build.sh` | no (local) | no | `make install` + prepend `/opt/mpd/bin` to PATH in the dev user's `~/.bashrc` (before the non-interactive guard so it applies to login, interactive, AND sshd-invoked non-interactive shells). Also exports PATH in the running shell. |
| `60-wireguard.sh` | no (local) | no | Gated on `/var/lib/mpd/conf/wireguard/mpd0.conf`. When present: sysctl `ip_forward=1`, install conf to `/etc/wireguard/mpd0.conf`, enable + start `wg-quick@mpd0`. |

Steps `10` and `20` are wgettable because they must run before the mpd
repo exists on disk. They inline their own helpers and don't source
`00-common.sh`. Everything from `30` on lives in the repo and sources
`00-common.sh` for shared logging helpers.

## Invocation flows

### Sandbox VM (user-driven, inside the VM)

The user-facing wrapper at `setup/sandbox/take-over-sandbox-vm.sh` is
itself wgettable; it chains 10 + 20 + 30..60 + sandbox-specific
finalize (VS Code, GNOME launcher, `mpd --setup`, pre-warm).

```bash
bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/setup/sandbox/take-over-sandbox-vm.sh)
```

### Managed VM (mpd-virt-macos / mpd-virt-linux / mpd-virt-windows)

Each orchestrator clones a **pure Debian template**, gets SSH access
(`ssh-copy-id` or cloud-init-injected key), then runs the steps:

```text
ssh -t … bash <(wget -qO- …/bootstrap/10-passwordless-sudo.sh)   # one interactive root pw
ssh    … bash <(wget -qO- …/bootstrap/20-git-clone.sh)
ssh    … bash /opt/mpd/bootstrap/30-networking.sh <NNN>          # SSH drops on IP change
# reconnect at new static IP
ssh    … bash /opt/mpd/bootstrap/40-install-software.sh
ssh    … bash /opt/mpd/bootstrap/50-build.sh
ssh    … bash /opt/mpd/bootstrap/60-wireguard.sh
ssh    … mpd --setup
```

Cloud-init flows (KVM, Hyper-V) handle the sudo bit via their
`user-data` natively, so step 10 is a silent no-op there.

### Upgrade (any VM)

```bash
cd /opt/mpd && git pull --ff-only
bash bootstrap/30-networking.sh <NNN>
bash bootstrap/40-install-software.sh
bash bootstrap/50-build.sh
bash bootstrap/60-wireguard.sh
```

All steps are idempotent — re-running everything is fine, costs only
the time of `dpkg -s` checks and a `make install` that detects no
changes.

## Environment variables (steps 10 + 20)

| Var | Default | Used by | Meaning |
|---|---|---|---|
| `MPD_REPO` | `https://github.com/mutms/mpd.git` | `20-git-clone.sh` | full https URL of the mpd repo |
| `MPD_BRANCH` | `main` | `20-git-clone.sh` | branch / ref to clone |

The wget URL for the seed scripts encodes the branch in its path
(`raw.githubusercontent.com/<owner>/mpd/<branch>/bootstrap/…`) — set
`MPD_BRANCH` to match if you wget from a non-main branch.
