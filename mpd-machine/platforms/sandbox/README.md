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
| `take-over-vm.sh` | Entry point. Hostname gate + disclaimer + sudo bootstrap + repo clone (if needed) + hand off to `lib/provision.sh`. |
| `lib/provision.sh` | The work: apt deps, `make install`, `mpd --setup`, optional pre-warm. |

## Prerequisites

- A clean **Ubuntu 26.04 LTS desktop** install in your hypervisor of
  choice. GNOME minimal is sufficient.
- Hostname renamed to **`mpd-machine-sandbox`**:
  ```bash
  sudo hostnamectl set-hostname mpd-machine-sandbox
  sudo sed -i 's/^127\.0\.1\.1.*/127.0.1.1\tmpd-machine-sandbox/' /etc/hosts
  # log out / log back in so your shell prompt picks up the new name
  ```
  This is the safety gate — `take-over-vm.sh` refuses any other
  hostname. Renaming the VM is a deliberate consent step, much harder
  to do by accident than typing a confirmation word.
- **A hypervisor snapshot taken before running `take-over-vm.sh`.** The
  script is destructive on purpose (passwordless sudo, system-wide CA
  trust, generated secrets). If anything goes wrong, your only rollback
  is the snapshot.

## Run it

```bash
bash mpd-machine/platforms/sandbox/take-over-vm.sh
```

If the mpd repo is not yet cloned at `~/Developer/mpd/`, the script
self-bootstraps: `apt install git`, clones
`https://github.com/mutms/mpd.git`, then hands off to `lib/provision.sh`
from the freshly cloned tree. This same script is therefore usable as a
future `curl | bash` installer with no separate packaging or release
artifacts.

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

## Reverting

`take-over-vm.sh` is destructive on purpose. The only supported rollback
is reverting your hypervisor snapshot.

There is **no** `uninstall.sh` shim in this directory: VM lifecycle
(start / stop / snapshot / revert / delete) is the hypervisor's job.
For a partial cleanup of mpd's runtime state without a full snapshot
revert, run `mpd --uninstall` — it removes `~/.mpd/`, podman containers,
and the `mpd-internal` network, while leaving `~/Developer/mpd/conf/`
and the system CA trust intact.

## Day-to-day

Once setup completes, mpd commands work identically to other
mpd-machine platforms — see
[`docs/machine/USAGE.md`](../../../docs/machine/USAGE.md).
