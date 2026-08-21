# Debugging problems

A growing catalogue of symptoms that have bitten real mpd setups, each
with the diagnostic that confirms it and the fix. If you hit something
not here, the general shape is: reproduce it reliably, find the resource
or limit being exhausted, then check whether it's the container, systemd
inside the container, or the host.

## A shell keeps the old environment after a runtime asset changes

**Symptoms.** An environment change that should be live — mpd ships or
edits a `project_types/<type>/shellrc.sh`, or you edit the runtime's
`~/.bashrc` — has no effect in the shell you are sitting in. The
signature case is Astro answering

```
Blocked request. This host ("<project>.<NNN>.mpd.test") is not allowed.
```

because `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS` is missing from the
shell that started the dev server (see USAGE.md, "Tools available inside
the runtime").

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
confirmation. Check you are in the runtime and not the VM while you are
there — `hostname` should end in `-runtime`; the VM does not source
runtime assets and never will.

**Fix.** Start a new session. `exec bash` is enough for a plain shell.
For JetBrains, **fully exit the IDE** and wait for its SSH session to
drop before reconnecting — the IDE terminal's environment comes from the
IDE's session, not from the tab.

No `mpd --runtime-rebuild` is needed. A rebuild replaces `~/.bashrc` with
the shipped skel, which carries the same hook, but it also recreates the
container — `~/.nvm` lives in that overlay and would need
re-provisioning. Reconnecting is the cheap fix.

## IDE / SSH sessions lock up: "Resource temporarily unavailable"

**Symptoms.** After a while — often "every hour", or reliably a few
minutes after connecting a heavy IDE — the runtime starts failing to
create threads or processes:

- JetBrains (PhpStorm Gateway / Remote Dev): `Error updating changes:
  [host] unable to create threaded lstat: Resource temporarily
  unavailable` (that message is `git status` failing to spawn its
  parallel `lstat` thread pool).
- Any interactive shell: `bash: fork: retry: Resource temporarily
  unavailable`.
- New `ssh` sessions hang or refuse; sometimes it clears on its own
  (something exited and freed a slot), sometimes the runtime wedges.

The common thread is `EAGAIN` from `fork`/`pthread_create` — the process
wanted a new task and the kernel refused because a **task-count limit**
was full.

**Cause.** Two limits stacked on top of each other, and the smaller one
bites first:

1. The container's `pids` cgroup limit. Podman/Docker default it to
   **2048**.
2. systemd, running as PID 1 *inside* the runtime, derives
   `DefaultTasksMax` = **15% of that** = **307**, and applies it to
   *every* service — including `ssh.service`. Because logind isn't
   carving each login into its own scope, **every** SSH session and
   long-lived IDE daemon shares that one `ssh.service` budget. A modern
   JetBrains backend (`jetbrainsd` + the `ijent` agent) alone runs
   ~256 threads, and a persistent JetBrains Toolbox daemon holding the
   SSH channel open keeps that floor high. Your interactive shell plus
   git's `lstat` pool then tips the service past 307 → `EAGAIN`.

The container-wide 2048 *looks* generous, so the real wall — a systemd
default nobody set, sitting 6.7× lower — is easy to miss.

**Diagnose.** From inside the VM (or `podman exec` into the runtime),
one command tells you whether you're in the trap:

```bash
sudo systemctl show ssh.service -p TasksMax
```

- `TasksMax=307` → you're in the trap.
- `TasksMax=infinity` → this ceiling is not your problem; look
  elsewhere (container `pids.max`, host memory, `RLIMIT_NPROC`).

To watch it happen, sample the service's live task count while the IDE
is connected:

```bash
# leaf cgroup of the SSH session tree, and its usage vs. cap
C=mpd-<NNN>-runtime
sudo podman exec "$C" systemctl show ssh.service -p TasksMax -p TasksCurrent
```

`TasksCurrent` climbing toward `TasksMax` under load confirms it.

**Fix.** Current mpd runtimes already ship the fix, so this mostly
matters for an older runtime built before it, or for other
systemd-in-container setups:

- The base image bakes a systemd drop-in
  (`/etc/systemd/system.conf.d/mpd-tasksmax.conf`) setting
  `DefaultTasksMax=infinity`, so no service inherits the tiny cap.
- The runtime container is created with `--pids-limit 32768`
  (`runtime.PidsLimit`) — a generous but finite ceiling, so the outer
  `pids` cgroup has room while a runaway fork bomb still hits a wall.

Rebuild to pick both up: `mpd --runtime-rebuild`.

If you need relief *without* a rebuild (or on an older runtime you don't
want to recreate yet), apply it live — these persist across VM reboots
and container restarts, and are lost only on a runtime recreate/rebuild:

```bash
C=mpd-<NNN>-runtime
# lift systemd's per-service cap for all services
sudo podman exec "$C" sh -c 'mkdir -p /etc/systemd/system.conf.d && \
  printf "[Manager]\nDefaultTasksMax=infinity\n" \
  > /etc/systemd/system.conf.d/mpd-tasksmax.conf'
sudo podman exec "$C" systemctl daemon-reexec
sudo podman exec "$C" systemctl set-property ssh.service TasksMax=infinity
# raise the outer container pids cgroup
sudo podman update --pids-limit 32768 "$C"
```

**Who else this bites.** Any systemd-in-container setup where the IDE
backend lands in a systemd-managed cgroup — distrobox/toolbx with
systemd, devcontainer images running systemd, Kubernetes sidecars — is
exposed to the same 307 trap and most won't have set `DefaultTasksMax`
either. Setups *without* systemd in the container (moodle-docker, DDEV,
Lando, plain `docker exec`) don't have the per-service cap; their only
ceiling is the container's `pids-limit`, which the IDE alone won't reach.
The trigger is getting worse for everyone regardless: newer JetBrains
backends burn more threads, so every setup now runs closer to whatever
its ceiling is.

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
→ `/etc/cloud/cloud.cfg.d/99-mpd.cfg`). After the next reboot the grep
count stays put and the block survives. A VM from the Debian installer has
no cloud-init and never shows this; if its `/etc/hosts` loses the block,
look for whatever else edits the file (`grep -rl /etc/hosts /etc/dhcp
/lib/dhcpcd /etc/NetworkManager`).

## A container resolves a database or LAN name to a stale address

**Symptoms.** Inside the runtime, `getent hosts <id>.db.<NNN>.mpd.test`
answers an address that is not what `grep <id> /etc/hosts` on the VM
shows, and `dig @10.163.<NNN>.1 <name>` from the same container gives the
right one.

**Cause.** The container's own `/etc/hosts` carries a copy of the VM's
from the moment it was created — podman's default base hosts file — and
glibc's `files` lookup wins over DNS. Containers mpd creates now get
`--hosts-file=none`, so only one created before that change can show this.

**Diagnostic.** `podman exec <container> grep mpd.test /etc/hosts` — any
mpd name in there is the snapshot.

**Fix.** Recreate the container: `mpd --runtime-rebuild` for the runtime,
`mpd --db-delete` + `mpd start <project>` for a database, `mpd
--service-uninstall` + `--service-enable` for a service.
