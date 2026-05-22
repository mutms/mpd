# `bootstrap/` — bring a Debian Trixie VM to the state `mpd --setup` expects

These scripts are the single source of truth for VM-side bring-up. Every
caller invokes the same `bootstrap/run-all.sh`; the bash never lives in
two places.

## Callers

| Caller | Invocation | Hostname state |
|---|---|---|
| `setup/sandbox/take-over-sandbox-vm.sh` | `bash bootstrap/run-all.sh 0` | `mpd-sandbox` → renamed to `mpd-000` by step 20 |
| `mpd-virt create <NNN>` (host) | `bash bootstrap/run-all.sh <NNN>` over SSH | template clone (`mpd-template`) → renamed to `mpd-<NNN>` by step 20 |

There's no separate "template-builder" mode — the template VM is just an
ordinary VM you preserve in Parallels (or similar) after running bootstrap
on it. mpd-virt re-runs the full bootstrap on every clone; it's
idempotent, so apt installs and `make install` are fast no-ops on a
template-derived VM.

**Important for host orchestrators (e.g. `mpd-virt-macos`):** push
host-provided artefacts (CA cert at `~/.mpd/conf/caroot/`, WireGuard
conf at `~/.mpd/conf/wireguard/mpd0.conf`) **before** running
`bootstrap/run-all.sh`. Step 50 reads the WG conf at bootstrap time;
pushing afterward means re-running bootstrap.

## Steps

| Step | What it does | Interactive? |
|---|---|---|
| `00-common.sh` | sourced library — logging helpers, hostname gate, distro gate. | — |
| `10-passwordless-sudo.sh` | writes `/etc/sudoers.d/00-mpd-<user>` via `su -c` if `sudo -n true` fails. | only on truly fresh Debian (one-time root password prompt) |
| `20-networking.sh` | renames hostname to canonical form; standardises NetworkManager + systemd-resolved + libnss-resolve; pins static IP when octet ∈ 100..254. | no |
| `30-install-software.sh` | apt-installs the full package set the in-VM `mpd` binary needs at runtime + build deps; enables `podman-restart.service`. | no |
| `40-build.sh` | `make install` + adds `bin/` to PATH via `~/.bashrc` snippet. | no |
| `50-wireguard.sh` | gated on `~/.mpd/conf/wireguard/mpd0.conf` (pushed in by the host orchestrator before bootstrap). When present: sysctl `ip_forward=1`, install conf to `/etc/wireguard/mpd0.conf`, enable + start `wg-quick@mpd0`. When absent: no-op. | no |
| `run-all.sh` | dispatches the steps in order. Takes the octet as its only argument. | inherits interactivity from step 10 only |

## Hostname accept-list (`00-common.sh`)

| Hostname | Meaning |
|---|---|
| `mpd-template` | template VM, before being cloned into a numbered VM |
| `mpd-sandbox` | sandbox VM, transitional — user typed this into the Debian installer; step 20 renames it to `mpd-000` |
| `mpd-NNN` | canonical 3-digit form; `mpd-000` is sandbox (DHCP), `mpd-100..254` are managed (static IP) |

## After bootstrap

`mpd --setup` does no apt work — it just asserts every package is present
and fails loudly with a "re-run `bootstrap/run-all.sh`" message if anything
is missing. Setup focuses on Podman networks, the data volume, services,
CA generation and trust, the WireGuard wg-quick install (when an mpd-virt
push left `~/.mpd/conf/wireguard/mpd0.conf` behind), and runtime
reconciliation.
