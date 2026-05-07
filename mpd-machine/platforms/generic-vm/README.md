# Generic VM bootstrap (Debian Trixie)

Bootstrap path for `mpd-machine` on a Debian Trixie VM installed from the
official Debian netinst ISO — either
**`debian-13.4.0-arm64-netinst.iso`** (Apple Silicon, ARM Linux) or
**`debian-13.4.0-amd64-netinst.iso`** (Intel / AMD x86). Any hypervisor
that boots a Debian netinst ISO works (UTM, QEMU, libvirt/KVM, Hyper-V,
etc.); the rest of the flow is identical regardless of arch or
hypervisor.

If you're on macOS + UTM and want the VM created for you (cloud-image
path with cloud-init, no installer prompts), start with
`../macos-utm/README.md` instead. Its `create-vm.sh` ends where this guide
begins. Note: the macOS + UTM automation is arm64-only.

> **Supported install only.** We test exclusively against the Debian 13
> Trixie netinst ISO (`debian-13.4.0-arm64-netinst.iso` or
> `debian-13.4.0-amd64-netinst.iso`). Other media (DVD, live, cloud
> images, other distros, other Debian releases) may work but aren't
> supported — they land you in subtly different states (root may or may
> not be configured, default package selection differs, etc.) that this
> guide doesn't account for. Stick to the supported ISOs.

## Bootstrap

`mpd-machine` makes invasive changes to the host it runs on (network config,
podman containers, sudo-installed CA + DNS resolver). Use a **sandbox VM
you can wipe and rebuild**, never a machine you care about.

The flow assumes you know how to drive a VM and git/SSH:

1. **Install Debian Trixie** in a fresh VM from the matching netinst
   ISO for your VM's architecture (`debian-13.4.0-arm64-netinst.iso` for
   arm64, `debian-13.4.0-amd64-netinst.iso` for amd64). Download from
   <https://www.debian.org/releases/trixie/>. The netinst installer
   prompts for, in order:

   - **Hostname**: `mpd-machine`, or `mpd-machine-<digits>` (e.g.
     `mpd-machine-158`) if you want the hostname to track the VM's
     last IP octet — handy for distinguishing concurrent VMs in shell
     prompts and PHPStorm sessions. `provision-vm.sh` validates against
     `^mpd-machine(-[0-9]+)?$` and refuses other names. If you set
     a static IP at the network-config step below, `provision-vm.sh`
     auto-renames the hostname to match the IP's last octet anyway,
     so the value you pick here is mostly for the DHCP-only path.
     If you missed the prompt, rename after the fact (login as root):
     ```bash
     hostnamectl set-hostname mpd-machine
     echo '127.0.1.1   mpd-machine' | sudo tee -a /etc/hosts
     ```
   - **Root password**: set one when prompted; don't leave it blank.
     Step 3 below depends on `su -` working.
   - **User account**: create your real user with its own password.
     Use the **same account name as your laptop login** — mpd assumes
     laptop user == VM user == runtime user, which is what lets the
     `ssh-copy-id 192.168.64.xx` and `ssh 192.168.64.xx` forms below
     work without explicit `user@`.
   - **Software selection**: tick "SSH server" and "standard system
     utilities". GNOME desktop is optional — only needed for the
     desktop-in-VM workflow described later on this page.

   The VM needs an IP reachable from your laptop. Note it down — you'll
   use it in step 2.
2. **Add your laptop's SSH key to the VM**, where `192.168.64.xx` is
   the VM's IP:
   ```bash
   ssh-copy-id 192.168.64.xx
   ```
   You will be asked for the user password you set during the install.
   SSH into your VM:
   ```bash
   ssh 192.168.64.xx
   ```
3. **Enable passwordless sudo for your account.** Chicken-and-egg: you need
   sudo to grant sudo, so do it once via `su -c`. You'll be prompted for the
   root password set during install.
   ```bash
   su -c "apt-get install -y sudo && install -m 440 /dev/stdin /etc/sudoers.d/$USER <<< '$USER ALL=(ALL) NOPASSWD:ALL'"
   ```
   Verify back in your user shell:
   ```bash
   sudo -n true && echo OK
   ```
   Required at mpd runtime (apt installs, resolver/CA, rootful podman) and
   used by `provision-vm.sh` as a sandbox-VM gate. If running this makes you
   nervous on the host you're typing it on, you're on the wrong host.
4. **Clone mpd repo** into `~/Developer/mpd`:
   ```bash
   sudo apt-get install git -y
   git clone https://github.com/mutms/mpd.git ~/Developer/mpd
   ```
5. **Run the bootstrap script** `provision-vm.sh`:
   ```bash
   bash ~/Developer/mpd/mpd-machine/platforms/generic-vm/provision-vm.sh
   ```
   The script runs in two phases with a reboot in between (see below).
   If anything goes wrong you can run the provision script again — it is
   re-entrant and idempotent.

`provision-vm.sh` validates the hostname (`mpd-machine` or
`mpd-machine-<digits>`), Debian Trixie, refuses to run as root,
verifies passwordless sudo works (`sudo -n true`), prompts you to
echo back the current hostname to confirm intent, then:

- disables SSH password authentication (pubkey only — your key is already in)
- prompts for `MPD_CLIENT_OS` (laptop OS for setup recipes) and the
  network mode (**static** vs **DHCP**); for static, auto-detects the
  current default gateway, IP, prefix, and DNS as defaults and lets
  you accept or override each. Writes the result to `conf/platform.env`.
  When static is chosen, the hostname is auto-renamed to
  `mpd-machine-<octet>` so it tracks the IP's last octet.
- ensures `~/.local/bin` is on PATH (for user-installed CLIs)
- **Phase 1 — network stack:** apt-installs `systemd-resolved` (if missing)
  and standardizes the host network stack to `systemd-resolved` fed by
  either NetworkManager (GNOME/KDE installs) or systemd-networkd. On a
  Trixie netinst-without-GNOME this means migrating ifupdown+dhcpcd →
  systemd-networkd; on a NetworkManager-managed install, it applies the
  static IP via `nmcli connection modify`. The script then asks you to
  **press Enter to reboot** (it runs `sudo reboot` for you) so DNS comes
  back up cleanly under the new link manager (`systemd-resolved`'s
  postinst replaces `/etc/resolv.conf` with a stub symlink, but resolved
  has no upstream DNS until the new link manager pushes one at boot).
  If nothing actually changed, the reboot is skipped and phase 2 runs
  in the same invocation.
- **Phase 2 — build prerequisites:** apt-installs build-essential,
  pkg-config, make, swiftlang (Trixie's packaged Swift), git, curl,
  libnss3-tools, plus `spice-vdagent` + `spice-webdavd` for clipboard
  sync + folder share under QEMU/SPICE (idle on other hypervisors).
- runs `make install` to build `~/Developer/mpd/bin/mpd`, then symlinks it
  to `/usr/local/bin/mpd` so `mpd` resolves on PATH for every shell
- runs `mpd --setup` automatically — re-running the script is the
  fast path back if anything goes wrong (up-arrow + Enter twice across
  the reboot)

`mpd` enforces `~/Developer/mpd` as the source checkout location — don't
substitute another path.

## Run setup

```bash
mpd --setup
```

`mpd --setup` will:

- verify the VM is Debian Trixie (refuses to run otherwise)
- verify `systemd-resolved` is active (it should be, courtesy of
  `provision-vm.sh` phase 1) and bail with a hint to reboot/re-run
  `provision-vm.sh` if not
- install runtime + diagnostic packages via apt (no prompt; relies on the
  passwordless sudo set up above) — `podman`, `aardvark-dns`, `dnsutils`,
  `traceroute`, `tcpdump`, `lsof`, `curl` and friends, so the user has
  tools to debug if any later step misbehaves
- generate the local CA + service certificates
- auto-install the mpd CA in the VM trust store
- write `/etc/systemd/resolved.conf.d/mpd.conf` so `*.mpd.test` resolves
  via the in-VM dnsmasq container, and reload `systemd-resolved`
- configure the Podman network and data volume
- bring up always-on infra services: dnsmasq, portal, Adminer, fileaccess
  (data-volume `podman exec` target + pubkey ssh/scp at
  `fileaccess.service.mpd.test`, exposing `/srv/backups/` for project-backup
  transfer). Laptop reaches containers via plain routing — no WireGuard on
  machine mode.
- initialize runtime/database state caches
- print per-OS laptop client recipes (static route + DNS resolver +
  optional CA trust)

Re-running `mpd --setup` is idempotent.

## Verify

```bash
mpd --status
mpd --start
mpd --status
```

Then create a project:

```bash
mpd create moodle51
```

## SSH identities — laptop key, VM key, runtime access

`mpd --setup` writes a small set of public keys into every runtime container's
`authorized_keys`. Two sources, deduped:

1. **`~/.ssh/authorized_keys` on the VM** — already contains your laptop's
   public key (that's how you SSH into the VM in the first place). Mpd
   propagates it so `ssh -A user@vm` → `ssh -A user@<rt>.runtime.mpd.test`
   works end-to-end with the laptop's key, and the agent forwards through
   to the runtime so `git push` from inside the runtime authenticates with
   the same key.
2. **`~/.ssh/id_*.pub` on the VM** — a VM-local keypair. `mpd --setup`
   generates `~/.ssh/id_ed25519` if no `id_*.pub` exists yet, with no
   passphrase. This is the key you'll use when SSHing **from inside the VM**
   (e.g. a GNOME desktop terminal, a `tmux` session, anywhere there's no
   forwarded agent):

   ```bash
   ssh user@php.runtime.mpd.test       # uses id_ed25519, no -A needed
   ```

**Three flows, one mental model:**

| From → to | Auth | Use case |
|---|---|---|
| laptop → VM | laptop key | shell access, mpd CLI |
| laptop → runtime (`ssh -A`) | laptop key, agent-forwarded | dev work + `git push` |
| VM → runtime | VM key | local terminal in VM (GNOME desktop, tmux) |

**Important caveat:** runtimes only read `authorized_keys` at create time. If
you add a new key to `~/.ssh/` after a runtime exists, the running runtime
won't know about it — recreate the runtime (`mpd --runtime-delete <name>` then
re-create on next project). For now there is no `mpd --runtime-rekey` verb.

## Beyond bootstrap: desktop-in-VM and shareable images

Two patterns the setup unlocks once a VM is provisioned and a project exists:

**Beginner-friendly desktop-in-VM workflow.** Install Debian Trixie with the
GNOME desktop, complete bootstrap, then `mpd create <project> + configure`.
Open a GNOME terminal, `ssh user@php.runtime.mpd.test`, `cd /srv/projects/<project>`,
and start coding (Claude Code, Composer, Behat) right there. No SSH agent
forwarding to teach, no laptop-side route/DNS/CA setup to do, no `-A` flag —
the VM is the development environment in full. Lowest-friction path for first-
time Moodle plugin developers.

For this workflow, **use the QEMU hypervisor backend** (in UTM on Apple
Silicon: *New VM* → *Virtualize* → Linux; libvirt/KVM and Hyper-V also
work). The SPICE guest agents that `provision-vm.sh` apt-installs
(`spice-vdagent` + `spice-webdavd`) only activate under QEMU/SPICE —
clipboard sync host↔VM and host-folder share via WebDAV both light up
automatically, no VM restart needed. UTM's QEMU UI also exposes the
VM's IP, so DHCP is fine and you don't have to pin a static IP.

Browsing `https://<project>.mpd.test/` from inside the VM works in both
Chromium and Firefox-ESR with no warnings and no clicks:

- **Chromium-family** (Chromium, Chrome, Edge — `sudo apt install -y chromium`):
  `mpd --setup` imports the mpd CA into `~/.pki/nssdb/`, which these browsers
  read on Linux for SSL trust.
- **Firefox-ESR** (the only Firefox in Debian Trixie's main archive):
  `mpd --setup` writes `/usr/lib/firefox-esr/distribution/policies.json`
  referencing the mpd CA. Firefox loads this policy at every launch and
  applies it to every profile and every user on the VM. No `certutil`,
  no per-profile setup.

**Shareable VM image.** Once provisioned, a VM disk image is portable. Export
from your hypervisor, hand it to a teammate, they import and boot — `mpd
list` shows the projects, Chromium trusts `*.mpd.test` (CA already in their
NSS DB if you cloned with `~/.pki/nssdb/`), `ssh user@php.runtime.mpd.test`
works. Useful for onboarding teammates, workshop prep, and bug-repro images.

Two caveats for sharing:

- **Crypto material travels with the disk.** The mpd CA private key
  (`~/Developer/mpd/conf/caroot/rootCA-key.pem`) and the VM's SSH key
  (`~/.ssh/id_ed25519`) are on the image. Anyone with a copy can mint certs
  trusted by `*.mpd.test` and SSH into runtimes. Fine for trusted recipients;
  regenerate before public distribution (`mpd --uninstall && rm -rf
  ~/Developer/mpd/conf ~/.ssh/id_ed25519* && mpd --setup`).
- **`platform.env` may not match the recipient's host OS.** If the source VM
  was provisioned with `MPD_CLIENT_OS=macos`, a recipient on Linux/Windows
  will still see macOS laptop-side recipes from `mpd --setup`. Recipient
  edits `~/Developer/mpd/conf/platform.env` to match their setup. Has no
  effect on the inside-the-VM workflow.

## Notes

- On Linux there is no `podman machine` concept — `mpd-machine` assumes
  rootful native Podman is installed and runnable.
- No prebuilt binaries are committed to git; `bin/mpd` is built in the VM.
- Laptop-side route + DNS resolver + CA trust steps are manual (printed by
  `mpd --setup`).

## File transfer policy (host ↔ VM)

When `--setup` produces artifacts the host needs:

- **Setup recipe**: regenerate via `ssh user@vm "mpd --setup-info"` (plain
  text, pipeable to a local file).
- **CA cert**: `scp user@vm:~/Developer/mpd/conf/caroot/rootCA.pem .`
- **Project backups**: pull from the VM with
  `scp fileaccess.service.mpd.test:/srv/backups/<file> .` once the laptop
  route to the container subnet is in place.
- **Optional**: hypervisor shared folder (UTM/Hyper-V/KVM/etc.) mapped to
  the VM for bulk transfers.
- Never print private keys to terminal output.
- Canonical secrets stay in `~/Developer/mpd/conf/`.

## Recovery

If you lose the laptop's private SSH key, recovery depends on what console
access the hypervisor offers (single-user mode, rescue boot, snapshot
restore). The UTM-specific recovery procedure — including the
serial-console gotcha — is in `../macos-utm/README.md`.

For other hypervisors: boot into single-user mode (typically by appending
`init=/bin/bash` to the kernel command line in GRUB), `mount -o remount,rw
/`, edit your account's `~/.ssh/authorized_keys`, and reboot. Cheaper
alternative: rebuild the VM and migrate state.
