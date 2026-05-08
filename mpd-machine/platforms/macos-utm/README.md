# macOS + UTM bootstrap

Automation for `mpd-machine` on macOS using **UTM with its QEMU
backend** (arm64). For the platform-agnostic bootstrap (any Debian
Trixie VM you've already created yourself), see the generic-vm
platform at https://github.com/mutms/mpd

This directory is the supported flavor for laptop-driven Moodle plugin
development on Apple Silicon. QEMU+SPICE gives us clipboard sync,
dynamic display resize, and visible DHCP leases in UTM's GUI.

## Prerequisites

- Apple M1 or later.
- UTM installed (App Store or direct download).
- SSH key at `~/.ssh/id_ed25519` (or `id_rsa`) — the public key is
  injected into the VM via cloud-init.

## `create-vm.sh` — create a VM

`create-vm.sh` provisions a Debian Trixie VM end-to-end: downloads the
Debian cloud image, prepares cloud-init, imports into UTM, waits for SSH
+ cloud-init, clones `~/Developer/mpd` inside the VM, installs required
packages, and builds/installs `bin/mpd`. Final output tells you to run
`mpd --setup` inside the VM.

Run on the macOS host:

```bash
cd ~/Developer/mpd
bash mpd-machine/platforms/macos-utm/create-vm.sh
```

The script prompts for two values:

- **Last IP octet** on the vmnet shared bridge (default `158`). Drives
  the VM name (`mpd-machine-158`), its static IP (`192.168.64.158`),
  and the in-VM hostname (`mpd-machine-158`). Pick a different octet
  to add concurrent VMs side-by-side (e.g. `.158` + `.159`); each gets
  its own UTM display name, IP, and prompt name so shell sessions and
  PHPStorm connections are unambiguous.
- **Disk size** in GB (default `200`). The cloud image is ~3 GB and
  is resized to the chosen size before UTM imports it.

Multiple VMs can be created this way and run side-by-side (each gets
its own static IP and hostname). mpd's internal "active machine" label
always remains `mpd-machine` regardless of the chosen hostname suffix,
so all per-machine state lives at `~/.mpd/machines/mpd-machine/` inside
each VM independently.

### Why the VM IP is pinned

`create-vm.sh` pins the VM to `192.168.64.<octet>` via cloud-init's
network config so the bootstrap automation has a known IP to `scp`/`ssh`
to before the VM is fully up. The same IP is recorded as `MPD_VM_IP`
in the VM's `~/Developer/mpd/conf/platform.env`, and the laptop-side
recipes that `mpd --setup-info` prints reuse it. If you'd rather run
DHCP, follow the generic-vm guide (https://github.com/mutms/mpd) instead — UTM's QEMU GUI shows
DHCP-leased IPs in the VM details panel.

After the script finishes, SSH into the VM and run `mpd --setup`. The
post-bootstrap `mpd --setup` / `--status` / verification steps are the
same as on any VM platform — see the generic-vm guide §"Run setup"
and §"Verify" at https://github.com/mutms/mpd

### Switching between VMs sharing an IP

If you recreate a VM with the same octet (e.g. you delete `.158` and
create another `.158`), the host key will have changed:

```bash
ssh-keygen -R 192.168.64.158
```

clears the stale entry from `~/.ssh/known_hosts`. Concurrent VMs on
different octets don't have this problem.

## Pulling public client artifacts to the host

After `mpd --setup` completes inside the VM, two one-liners get the
public client artifacts onto the macOS host:

```bash
ssh "${USER}@${VM_IP}" 'PATH="$HOME/Developer/mpd/bin:$PATH" mpd --setup-info' > SETUP.txt
scp "${USER}@${VM_IP}:~/Developer/mpd/conf/caroot/rootCA.pem" rootCA.pem
```

`VM_IP` is `192.168.64.<octet>` for whichever octet you picked at
`create-vm.sh` time (recorded in the VM's
`~/Developer/mpd/conf/platform.env` as `MPD_VM_IP`). Both artifacts
are public — no private material — so it's safe to email or share
them.

## File transfer (host ↔ VM)

For UTM specifically, two transfer paths beyond `scp`:

- **UTM shared folder** — map a host directory into the VM (Edit > Sharing).
  Convenient for project backups or anything else that's bulky.
- **`scp/ssh` via fileaccess** — preferred for project backups. The
  `mpd-service-fileaccess` container exposes `/srv/backups/` (a data-volume
  subdirectory) as an SSH/scp endpoint at `fileaccess.service.mpd.test`.

Never print private keys to terminal output. Canonical secrets stay in
the VM's `~/Developer/mpd/conf/`.

## Recovery: lost SSH key

If you lose the laptop's private SSH key and can no longer log into the
VM, you can replace the public key from the UTM console using
single-user mode. The cloud-init defaults lock all passwords
(`lock_passwd: true`, `ssh_pwauth: false`) so a normal TTY login won't
work — but GRUB itself isn't password-protected, so booting straight to
a root shell is open.

**One UTM-specific gotcha first:** `create-vm.sh` doesn't attach a
graphical display device — the VM only has a serial console. By default
UTM may not route that to a usable window, so GRUB output and the TTY
are invisible. Switch the serial device to UTM's built-in terminal:

1. Stop the VM in UTM.
2. Right-click the VM > Edit > Devices, find the Serial / Console entry.
3. Change its mode (or "Output") to "Built-in Terminal". Save.
4. Start the VM — UTM opens a text terminal window where you can see
   GRUB and interact with the kernel console.

Then recover:

5. Reboot the VM. Press a key during the GRUB menu countdown to
   interrupt auto-boot.
6. Highlight the default entry, press `e` to edit, find the `linux ...`
   line, append `init=/bin/bash` to the end. Press Ctrl-X (or F10) to
   boot.
7. You land in a root shell with no auth. The root filesystem is mounted
   read-only, so:
   ```
   mount -o remount,rw /
   ```
8. Replace the public key:
   ```
   vi /home/<your-user>/.ssh/authorized_keys
   ```
9. `sync` and reboot (`exec /sbin/init` or power-cycle).

After recovery, switch the serial device back to its previous mode in
UTM; the built-in terminal is only needed when you want to interact with
GRUB or a TTY login.

**Faster alternative:** just rebuild the VM. `create-vm.sh` is cheap,
and a fresh VM rules out whatever made the original hard to access.
Run it with a different octet (e.g. `.159` if the old one is `.158`)
as a side-by-side experiment first; if everything works, delete the
old VM in UTM. The cost is whatever local-only state was in the old
VM (project sources, DBs, generated CA, fileaccess host keys) — git
remotes and laptop-side notes survive.