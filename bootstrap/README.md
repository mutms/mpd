# `bootstrap/` — bring a Debian Trixie vm to the state `mpd --vm-setup` expects

Bootstrap steps, each a single self-contained script you can run straight
from GitHub:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/bootstrap/10-passwordless-sudo.sh)
bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/bootstrap/15-secure-ssh.sh)
bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/bootstrap/20-install-software.sh)
bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/bootstrap/30-mpd-build.sh)
```

All are idempotent — re-running everything costs one `apt-get update`,
a `dist-upgrade` that finds nothing and a `make install` that finds
nothing. There is no orchestrator; callers list the steps.

## Scripts

### 10-passwordless-sudo.sh

Interractive, may ask for root password once.

Hostname gate (`mpd-<NNN>`, or a `mpd-template[-<suffix>]` / `mpd-sandbox[-<suffix>]` staging name),
Debian Trixie gate, refuses root. No-op if `sudo -n` already works; otherwise `su -c` installs
sudo if missing and writes `/etc/sudoers.d/00-mpd-<user>`.

### 15-secure-ssh.sh

Hardens a default Debian sshd with one drop-in (`/etc/ssh/sshd_config.d/10-mpd.conf`):
root over SSH off, password + keyboard-interactive auth off, keys only.
Refuses while your `~/.ssh/authorized_keys` holds no key (`ssh-copy-id` first);
no-op without openssh-server.

### 20-install-software.sh

`apt-get update` + `dist-upgrade`, adds the Sury and PGDG apt repos,
then **the Debian package list**: build deps, networking diagnostics, everything
the control plane needs at run time (podman, dnsmasq-base, caddy, WireGuard, nftables, …),
the DB clients, agent tooling, and avahi + qemu-guest-agent
(enabled; started where systemd runs and the hypervisor device exists).
No hostname gate — it also runs inside an image build.

### 30-mpd-build.sh

Creates `/opt/mpd` + `/var/lib/mpd` owned by the dev user; clones or fast-forwards
the mpd repo; `make install`; puts `/opt/mpd/bin`, `assets/vm/bin` and `~/.local/bin`
on PATH via `~/.bashrc`.

## Invocation flows

### Sandbox VM (user-driven, inside the VM)

`setup/mpd-sandbox-setup.sh` gates the hostname and sudo itself,
converts the network stack, then runs 20 + 30 from GitHub, `mpd
--vm-setup`, and the sandbox extras (pre-warm, GNOME launcher). It skips
15 on purpose: a sandbox may have no SSH key at all.

### Managed VM (`mpd-virt adopt` / `mpd-virt create`)

The orchestrator reaches a VM that has SSH key auth, then runs the
steps over SSH, pushes the CA (needs `/var/lib/mpd` from step 30), and
finishes with `mpd --vm-setup`:

```text
ssh -t … bash <(wget -qO- …/bootstrap/10-passwordless-sudo.sh)   # no-op on cloud-init VMs
ssh    … bash <(wget -qO- …/bootstrap/15-secure-ssh.sh)
ssh    … bash <(wget -qO- …/bootstrap/20-install-software.sh)
ssh    … bash <(wget -qO- …/bootstrap/30-mpd-build.sh)
ssh    … mpd --vm-setup
```

Cloud-init flows handle sudo in their `user-data`, so step 10 is a
silent no-op there. `mpd-virt` fetches the scripts at a pinned commit
(`bootstrapRef` in its `adopt.go`), not `main`.

### Template VM (pre-run 10 + 20)

Give a staging VM the hostname `mpd-template` (or `mpd-template-<x>`),
run 10, 15 and 20 in it, shut it down and clone from it. A clone renamed to
`mpd-<NNN>` adopts in the time of step 30 + `mpd --vm-setup` alone, and —
thanks to qemu-guest-agent and avahi — reports its IP to the hypervisor
and over mDNS, so `mpd-virt adopt <NNN>` finds it without an address.
Step 20 re-runs during adoption and converges a template that has gone
stale.

### Apple container image (mpd-virt)

`container/Containerfile` in mpd-virt runs step 20 at image-build time
(as root; the script's per-command `sudo` is then a no-op), so a VM
from the image is pre-baked like a template VM.

## Environment variables

| Var                    | Default                            | Used by | Meaning                                                                            |
|------------------------|------------------------------------|---------|------------------------------------------------------------------------------------|
| `MPD_REPO`             | `https://github.com/mutms/mpd.git` | 30      | https URL of the mpd repo (for mpd development only)                               |
| `MPD_BRANCH`           | `main`                             | 30      | branch / ref to clone (for mpd development only)                                   |
| `MPD_APT_LOCK_TIMEOUT` | `300`                              | 20      | seconds to wait for the dpkg lock (GNOME's packagekitd holds it right after login) |
| `MPD_APT_RETRIES`      | `3`                                | 20      | retries for a stalled package download                                             |
