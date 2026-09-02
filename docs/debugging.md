# Debugging problems

A growing catalogue of symptoms that have bitten real mpd setups, each
with the diagnostic that confirms it and the fix. If you hit something
not here, the general shape is: reproduce it reliably, find the resource
or limit being exhausted, then check whether it's the container, systemd
inside the container, or the host.

## A shell keeps the old environment after an asset changes

**Symptoms.** An environment change that should be live — mpd ships or
edits a `project_types/<type>/shellrc.sh`, or you edit `~/.bashrc` —
has no effect in the shell you are sitting in. The signature case is
Astro answering

```
Blocked request. This host ("<project>.<NNN>.mpd.test") is not allowed.
```

because `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS` is missing from the
shell that started the dev server (see usage.md, "Tools available in the
VM").

**Cause.** Bash reads `~/.bashrc` once, at session start. Nothing
re-reads it, so a session that predates the change keeps the old
environment for as long as it lives — and IDE sessions live a long time.
JetBrains (PhpStorm Gateway / Remote Dev) is the one that surprises
people: it holds its own SSH session open, and a terminal opened *inside*
the IDE inherits that session's environment. Closing the terminal tab is
not enough; the session outlives it.

**Diagnose.** In the shell that is misbehaving:

```bash
echo "$__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS"   # empty → stale session
grep -c shellrc.sh ~/.bashrc                     # non-zero → the hook IS installed
```

Those two disagreeing (hook installed, variable empty) is the
confirmation.

**Fix.** Start a new session. `exec bash` is enough for a plain shell.
For JetBrains, **fully exit the IDE** and wait for its SSH session to
drop before reconnecting — the IDE terminal's environment comes from the
IDE's session, not from the tab.

Nothing needs reprovisioning: `bashrc-include.sh` is read live from
`/opt/mpd`, so the next shell already has the change.

## RDP connects, authenticates, and shows a black screen

**Symptoms.** `rdp-start` has been run, the client connects, the password
is accepted — and you get a black screen. Nothing in the xrdp logs looks
wrong, because from xrdp's point of view nothing is: it authenticated,
started an X server, and handed off.

**Diagnostic.** `mpd --vm-diag` reports it directly. By hand:

```bash
loginctl list-sessions          # is there a seat0 session for your user?
ps -eo pid,args | grep gnome-session-failed
sudo tail /var/log/xrdp-sesman.log
```

The signature is `Xorg :10` alive and healthy, and
`gnome-session-failed --allow-logout` running under the RDP session.
That process *is* the black screen — it is GNOME's "Oh no! Something has
gone wrong" handler, which paints nothing over RDP.

**Cause.** GNOME runs once per user. If a console session already holds
that user's systemd session units — someone logged in at the hypervisor
console, or gdm is configured to log in automatically — the RDP session
cannot start a second shell and launches the failure handler instead.
The two ends share one user manager, so the collision can take the
console session down as well.

**Fix.** Have one owner of the desktop, not two:

```bash
gnome-stop                      # headless: gdm never runs, RDP owns GNOME
```

`gnome-stop` is the durable answer because xrdp starts its own X server
and never involves gdm — a desktop reached over RDP does not want a
display manager at all. `loginctl terminate-session <id>` clears the
current collision but not the next one.

**Check autologin.** If `/etc/gdm3/daemon.conf` has
`AutomaticLoginEnable=True`, the console claims the desktop at every
boot, so terminating the session is never a fix — it returns after a
reboot. `mpd --vm-diag` reports this separately from the live session.

The two consistent pairs are `gnome-stop` + RDP (desktop reached
remotely) and `gnome-start` + `rdp-stop` (desktop on the hypervisor
console). Both owners at once is the broken state.

## A `*.mpd.test` name stops resolving after a reboot

**Symptoms.** Right after a reboot, `getent hosts <project>.<NNN>.mpd.test`
on the VM answers nothing, and `grep 'BEGIN mpd' /etc/hosts` finds no
block. `mpd --vm-start` repairs it; the next reboot breaks it again.

**Cause.** Something rewrites `/etc/hosts` at boot. On a cloud-init image
that is cloud-init's `update_etc_hosts` module, driven by
`manage_etc_hosts: true` in the seed's user-data — Proxmox always sets it,
and its UI cannot switch it off. The user-data outranks every file under
`/etc/cloud/`, so a `manage_etc_hosts: false` drop-in changes nothing;
the module has to be taken out of the list it runs from.

**Diagnostic.**

```bash
grep -c 'Running module update_etc_hosts' /var/log/cloud-init.log   # grows by one per boot
cat /etc/cloud/cloud.cfg.d/99-mpd.cfg                               # missing, or lists the module
```

**Fix.** `mpd --vm-setup` installs the drop-in (`assets/vm/cloud-init-99-mpd.cfg`
→ `/etc/cloud/cloud.cfg.d/99-mpd.cfg`), which leaves cloud-init only the
disk-grow modules. After the next reboot the grep count stays put and the
block survives. The same drop-in is why an edit in Proxmox's cloud-init
tab does not rename the VM or regenerate its SSH host keys. A VM from the Debian installer has
no cloud-init and never shows this; if its `/etc/hosts` loses the block,
look for whatever else edits the file (`grep -rl /etc/hosts /etc/dhcp
/lib/dhcpcd /etc/NetworkManager`).

## `sudo cat DIR/*` fails on a root-owned 0700 directory

**Symptom.** A command that reads mpd's private state comes back with the
glob unexpanded, and no `sudo` prompt or permission error to explain it:

```
$ sudo -n cat /srv/dbs/postgres-18/pgdata/*.conf
cat: '/srv/dbs/postgres-18/pgdata/*.conf': No such file or directory
```

The variant that hurts more is silent: `sudo rm -f DIR/*` on such a
directory removes nothing and reports success.

**Cause.** The shell expands the glob *before* `sudo` runs, as the dev
user. A database engine owns its own data files, so directories under
`/srv/dbs/` are root-owned and unreadable to that user: the pattern
matches nothing and bash passes it through literally.

**Diagnose.** `sudo ls -ld <dir>` — if it is `drwx------ root root` and
you are not root, any glob you write against it in an unprivileged shell
is dead.

**Fix.** Expand inside a root shell:

```bash
sudo -n bash -c 'cat /srv/dbs/postgres-18/pgdata/*.conf'
```

Same over ssh, where the remote login shell does the expanding. Where the
file names are already known, name them instead of globbing.

## Both caddies run, nothing listens on :443

**Symptom.** `systemctl is-active caddy mpd-caddy` says `active` for
both, but `ss -lntp | grep :443` is empty and every URL — the portal and
every project — refuses the connection. No error in either journal; both
logs end with a cheerful `load complete`.

**Cause.** Caddy's admin API defaults to `localhost:2019`, and mpd runs
two caddies on the VM: `caddy.service` for the zone apex on `.1`, and
`mpd-caddy.service` for the project vhosts on `.2`. Both bind that same
admin socket — the kernel allows it — and `caddy reload` POSTs to
whichever answers. One instance's reload then loads into the other,
replacing its config wholesale. The loser ends up serving the empty
config `{}`: still running, still `active`, listening on nothing.

**Diagnose.** Two owners on one admin port, and an empty live config:

```bash
sudo ss -lntp | grep 2019          # two caddy pids on 127.0.0.1:2019
curl -s localhost:2019/config/     # {}
```

**Fix.** The project caddy takes its own endpoint: `admin localhost:2020`
in the global block of `assets/vm/caddy/templates/header.caddyfile`, and
`mpd-caddy.sh` passes `--address` to `caddy reload` so the reload reaches
the instance it belongs to. The apex keeps the default 2019.

Change one and you must change the other — a reload aimed at the wrong
endpoint is silent, and looks exactly like this symptom.

## HTTPS serves a superseded certificate after rotation

**Symptoms.** After a certificate rotation (CA change, `mpd start`
re-issuing a leaf), the browser or `curl -v` still gets the old
certificate from a project URL. The files on disk are correct:
`openssl x509 -in <certdir>/cert.pem -noout -dates` shows the new cert.

**Cause.** Caddy loads certificates into memory at config load and never
re-reads the files on its own. Rotation rewrites `cert.pem` but not the
Caddyfile, so a plain `caddy reload` (and the `--watch` mode) compares
configs, sees no change, and keeps serving the superseded cert from
memory.

**Diagnostic.** Compare what is served with what is on disk:

```bash
openssl s_client -connect <name>:443 -servername <name> </dev/null 2>/dev/null \
    | openssl x509 -noout -serial
openssl x509 -in <certdir>/cert.pem -noout -serial
```

Different serials with a correct file is the confirmation.

**Fix.** Reload with `--force`, which skips the config comparison. The
project caddy's watcher (`assets/vm/caddy/mpd-caddy.sh`) already
does this on every regeneration — do not "optimize" the flag away. For a
one-off recovery: `caddy reload --config <Caddyfile> --adapter caddyfile
--force`.

## `systemctl start qemu-guest-agent` blocks forever

**Symptoms.** A bootstrap or adoption script hangs at the guest-agent
step. `systemctl start qemu-guest-agent` never returns and never fails.

**Cause.** Debian's qemu-guest-agent unit has no `[Install]` section;
udev starts it when the virtio-serial device appears. The unit carries
`BindsTo=` on that `.device` unit, and device units have no job timeout —
on a VM without the device (VirtualBox, bare metal, some hypervisor
configs) the start job waits for it indefinitely instead of failing.

**Diagnostic.** `ls /dev/virtio-ports/org.qemu.guest_agent.0` — absent
means any `systemctl start qemu-guest-agent` will hang.

**Fix.** Gate the start on the device, never attempt-and-catch:

```bash
[ -e /dev/virtio-ports/org.qemu.guest_agent.0 ] && sudo systemctl start qemu-guest-agent
```

`bootstrap/20-install-software.sh` does exactly this. A hung job is
cleared with `sudo systemctl cancel` (or list it: `systemctl list-jobs`).

## The WireGuard overlay dies after `mpd --vm-setup`

**Symptom.** mpd-proxy on the laptop logs `Sending handshake initiation`
forever and every `*.<NNN>.mpd.test` lookup ends in `SERVFAIL ... i/o
timeout`. On the VM, `sudo wg show` lists no peer, and `ip route get
10.163.0.1` goes out `eth0` instead of `wg0`. The rest of the VM is fine;
SSH and SOCKS still work.

**Cause.** The VM's WireGuard key was regenerated. `EnsureWireGuard`
runs its script as the dev user, and `/etc/wireguard` is a root-only
`0700` directory, so an unprivileged `[ -f /etc/wireguard/mpd.key ]` is
false even when the file exists. The step then mints a new key and
writes a fresh `wg0.conf` with no `[Peer]`, and the restart loads it.
The peer's public key of the VM no longer matches, so the handshake never
completes. This is the same 0700 trap as the glob entry above, in a
different disguise.

**Diagnose.** Compare `sudo wg show wg0 public-key` with the VM key the
host holds. `sudo ls -la --time-style=full-iso /etc/wireguard/` shows
both files rewritten at the moment of the last `mpd --vm-setup`, and
`journalctl` around that time shows `tee /etc/wireguard/mpd.key`.

**Fix.** The guards now run as `sudo test -f`, and the unit is only
restarted when the conf was just written. To recover a VM that already
lost its peer: re-add it on the VM
(`sudo wg set wg0 peer <laptop-pubkey> allowed-ips 10.163.0.1/32`,
`sudo ip route replace 10.163.0.1/32 dev wg0`, `sudo wg-quick save wg0`)
then run `mpd-virt start <NNN>` on the host: it reads the VM's new
public key and re-registers the peer in mpd-proxy.
