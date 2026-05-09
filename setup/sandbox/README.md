# mpd-machine — sandbox platform

Graphical sandbox: install Ubuntu 26.04 LTS desktop in any hypervisor
(UTM / Hyper-V / VirtualBox / virt-manager / VMware / etc.), take a
hypervisor snapshot, run one script. mpd lives entirely inside the VM;
the host gets zero DNS / route / trust changes.

The hypervisor owns VM lifecycle (start / stop / snapshot / revert from
its own GUI); mpd inside owns project lifecycle (`mpd create / start /
stop / configure`).

## Files in this directory

| File | What it does |
|---|---|
| `take-over-sandbox-vm.sh` | Entry point. Hostname gate + disclaimer + sudo bootstrap + repo clone (if needed) + hand off to `lib/provision.sh`. |
| `lib/provision.sh` | The work: apt deps, `make install`, `mpd --setup`, optional pre-warm. |

## Prerequisites

- A clean **Ubuntu 26.04 LTS desktop** install in your hypervisor of
  choice. GNOME minimal is sufficient.
- Hostname **`mpd-machine-sandbox`**. Easiest is to type that name into
  the hostname field during the Ubuntu installer. If you already
  installed with a different hostname, rename now:
  ```bash
  sudo hostnamectl set-hostname mpd-machine-sandbox
  sudo sed -i 's/^127\.0\.1\.1.*/127.0.1.1\tmpd-machine-sandbox/' /etc/hosts
  # log out / log back in so your shell prompt picks up the new name
  ```
  The hostname is the safety gate — `take-over-sandbox-vm.sh` refuses
  any other hostname. Renaming the VM is a deliberate consent step,
  much harder to do by accident than typing a confirmation word.
- **A hypervisor snapshot taken before running the take-over script.**
  The script is destructive on purpose (passwordless sudo, system-wide
  CA trust, generated secrets). If anything goes wrong, your only
  rollback is the snapshot.

## Run it

Inside the VM, either curl-bash directly:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/mutms/mpd/main/setup/sandbox/take-over-sandbox-vm.sh)
```

…or, if the repo is already cloned:

```bash
bash ~/Developer/mpd/setup/sandbox/take-over-sandbox-vm.sh
```

In standalone mode (no repo present), the script self-bootstraps:
`apt install git`, clones `https://github.com/mutms/mpd.git` to
`~/Developer/mpd/`, then hands off to `lib/provision.sh` from the
freshly cloned tree.

## What it does

1. Hostname gate — must be `mpd-machine-sandbox`.
2. OS gate — must be Ubuntu 26.04.
3. Disclaimer + Enter-to-proceed.
4. Enables passwordless sudo (one-time password prompt for the install).
5. apt-installs `git` if missing; clones the repo if missing.
6. apt-installs `build-essential pkg-config make swiftlang libnss3-tools qemu-guest-agent`.
7. `make install` of mpd; symlinks `/usr/local/bin/mpd`.
8. Writes `~/Developer/mpd/conf/platform.env` with `MPD_PLATFORM=sandbox`.
9. `mpd --setup` — generates the CA, installs system trust + Firefox
   policies + `~/.pki/nssdb` import, brings up podman + dnsmasq + portal
   + adminer + fileaccess.
10. Best-effort pre-warm: `mpd --runtime-create=php` and
    `mpd --db-create=postgres:latest`.
11. Drops a GNOME launcher (`~/.local/share/applications/mpd.desktop`,
    plus `~/Desktop/mpd.desktop` when desktop icons are on) that opens
    `mpd --tui` in the user's default terminal.

## Reverting

`take-over-sandbox-vm.sh` is destructive on purpose. The only supported
rollback is reverting your hypervisor snapshot.

There is **no** `uninstall.sh` shim in this directory: VM lifecycle
(start / stop / snapshot / revert / delete) is the hypervisor's job.
For a partial cleanup of mpd's runtime state without a full snapshot
revert, run `mpd --uninstall` — it removes `~/.mpd/`, podman containers,
and the `mpd-internal` network, while leaving `~/Developer/mpd/conf/`
and the system CA trust intact.

## Day-to-day

Once setup completes, mpd commands work identically to other
mpd-machine platforms — see
[`docs/machine/USAGE.md`](../../docs/machine/USAGE.md).
