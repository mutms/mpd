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
