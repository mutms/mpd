# Proposal: `/srv` on the VM, `mpd run`, and retiring fileaccess

Status: draft, 2026-07-21. Delete this file when it ships — the code and
the canonical docs become the record.

## Motivation

Project setup wants to happen **on the VM**, not inside the php runtime.
Daily development stays as it is today (PhpStorm over SSH into the
runtime), but the moments around a project's birth and death — scaffolding
it, editing `mpd.env`, inspecting a backup — belong to the VM shell, where
`mpd` itself lives.

Three things fall out of that, in increasing order of value:

1. A VM-side `php` or `mudev` that forwards into the project's runtime, so
   a one-off command doesn't need an SSH hop first.
2. `mpd start` with no argument inside `/srv/projects/moodle45` meaning
   "start moodle45", the same way in-runtime tools already infer their
   project by walking up to `mpd.env`.
3. **Authoring `mpd.env` before any runtime exists**, which lets the
   project declare its own runtime (`MPD_RUNTIME=php`) instead of taking
   it from a flag at create time. The project becomes the source of truth
   for its own placement.

All three need one thing: the `/srv` tree visible on the VM, at the same
path it has inside containers.

## What makes this cheap

`/srv` is the named volume `mpd-data-volume` (`runtime.go:137`), created
at `mpd --vm-setup` (`cli/setup.go:355`) — so it exists before any runtime
does. Podman runs rootful (via `sudo`), and the runtime dev user is created
with the VM's own UID (`bootstrap.sh`: `useradd -u "$EXTUID"`). The volume's
contents are therefore **already owned by the VM's dev user, with real
UIDs**:

```
/var/lib/containers/storage/volumes/mpd-data-volume/_data
  drwxrwxr-x skodak skodak  projects
  drwxrwxr-x skodak skodak  backups
  drwxr-xr-x root   root    dbs
```

No userns ID-shifting to undo. The only thing standing between the VM user
and those files is `/var/lib/containers/storage/volumes`, which is `0700
root` and can't be traversed.

Directory hardlinks are not an option — Linux forbids them. Symlinking
`/srv` at the volume path would mean loosening podman's storage
permissions and hoping podman doesn't reassert them. That leaves a bind
mount, which sidesteps the traversal problem entirely: root performs the
mount once, and access checks afterwards apply to `/srv`, not to the
source path chain.

## Change 1 — `srv.mount`

`mpd --vm-setup` writes and enables a systemd mount unit. The unit name
must be `srv.mount`; systemd derives it from the mount point.

```ini
[Unit]
Description=mpd data volume at /srv
ConditionPathIsDirectory=<source>

[Mount]
What=<source>
Where=/srv
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
```

`<source>` is resolved at setup time from `podman volume inspect -f
'{{.Mountpoint}}' mpd-data-volume`, never hardcoded — the path is a podman
implementation detail and we should read it rather than assume it.
`go/internal/vm` already owns systemd unit generation (the shutdown unit),
so this lands there; the podman query goes through `go/internal/podman`.

The result is **path identity**: `/srv/projects/moodle45` is the same
string on the VM and inside every runtime, exactly as `/opt/mpd` already
is. Every downstream convenience in this proposal depends on that property
and on nothing else.

This change is purely additive. The volume stays a named volume, and the
existing `Volume*` plumbing keeps working untouched until change 3 removes
it.

## Change 2 — `mpd run`

A general passthrough: run a command inside the runtime that owns the
current project.

```
mpd run [--] <command> [args…]
```

### Project context is mandatory

`mpd run` works **only inside `/srv/projects/<name>/` or a subdirectory
of it.** Outside that tree there is no project, and without a project
there is no runtime to execute in — the command has no meaning, and there
is nothing sensible to guess. Refuse with an actionable message rather
than picking a runtime.

Resolution:

- Normalise `$PWD` (absolute, symlinks resolved) and require it to be
  `/srv/projects/<name>` or below. Normalising first is what stops
  `../..` and symlink games from walking out of the tree.
- Look up `<name>` in `projects.json`. Not registered → error. That file
  carries `RuntimeName`, which is the answer we actually need.

Note this is **not** the in-runtime tools' rule (walk up to `mpd.env`,
take the basename). Tools use that because a runtime container cannot see
`projects.json` — the state dir isn't mounted into runtimes — so `mpd.env`
is their only local evidence. On the VM the registry is right there, and a
path check has two advantages: it can't be spoofed by a stray `mpd.env`
elsewhere on the VM, and it still resolves a project whose `mpd.env` is
missing or not yet written.

Behaviour:

- Exec in the project's runtime as the dev user with `-w "$PWD"` —
  correct verbatim, thanks to path identity.
- Propagate the child's exit code. Wrappers are useless otherwise.
- Allocate a TTY when stdin is one, so interactive commands work.
- Fail with something actionable when the runtime is stopped.

`run` joins `cli.ProjectVerbs`, which reserves it as a project name. Note
it is the first verb with a *non-project* second argument — the grammar is
`mpd run <command>`, not `mpd <verb> <project>`. That's worth calling out
in `CLI_BEHAVIOR.md` rather than letting it be inferred.

### Wrapper shims

With `mpd run` in place, a VM-side `php` or `mudev` is trivial and — this
is the point — contains **no podman knowledge**:

```bash
#!/bin/bash
# Forward to the same-named command inside the project's runtime.
# A shim may be prefixed when the bare name is unsafe on the VM (see
# below); the runtime knows the command by its bare name either way.
cmd="${0##*/}"
exec /opt/mpd/bin/mpd run -- "${cmd#mpd-}" "$@"
```

One script in `/opt/mpd/bin/`, with a symlink per forwarded command
resolving via `$0`. That directory is already the home for VM-side
scripts (`claude-install`, `demo`, `gnome-start`, `gnome-stop` are
committed there; only the built `bin/mpd` is gitignored) and is already on
the dev user's PATH — `bootstrap/50-build.sh` writes
`PATH="$HOME/.local/bin:/opt/mpd/bin:$PATH"` into `~/.bashrc`. No new
mechanism, no `/etc/profile.d/` drop-in, nothing to wire at `--vm-setup`.

### Shim naming: bare, because the VM deliberately has none of these

`/opt/mpd/bin` is **prepended** to PATH, so a shim named `php` claims
that name VM-wide. That is acceptable — and preferable — given two
properties that hold together:

**The mpd VM has no PHP and no Node.** `bootstrap/40-install-software.sh`
installs neither, and `--no-install-recommends` keeps them from arriving
as dependencies. Deliberate, and worth protecting: there is no real
binary for the shim to shadow.

**The shim inherits the project-context constraint.** Outside
`/srv/projects/<name>/` it does not forward, it *refuses* — and the
refusal is the useful part. After `/srv` is mounted the VM shell can see
every project tree, so typing a runtime command there becomes plausible;
the answer should be

```
php: not inside a project (/srv/projects/<name>/).
Wrong directory — or wrong terminal? Runtime commands belong in the
runtime: ssh user@<rt>.runtime.<zone>
```

which locates the user far better than `command not found` does. Inside a
project, `php` meaning "this project's php" is simply correct.

So bare names, with one condition attached:

> **A VM-side shim may take a bare upstream name only when the VM
> deliberately never provides that command.** If a real host binary could
> legitimately exist, the shim takes the `mpd-` prefix instead — the
> silent-shadowing failure (a command that looks local, running elsewhere,
> against a different filesystem) is worse than an ugly name.

mdc split the same way, if by a different route: `mdc-php`, `mdc-bash`
and `mdc-debug` are prefixed because on a laptop those names are all
taken, while `behat`, `grunt`, `phpunit` and `mpci` stay bare because
nothing on the host answers to them. On a purpose-built VM the set of
"taken" names is much smaller, so more shims can be bare.

Consequence, accepted deliberately: **the shim wins even if PHP is
installed on the VM later.** `/opt/mpd/bin` is prepended, so an
apt-installed `/usr/bin/php` never gets a look in — `php` in a
non-project directory would report "not inside a project" rather than
running the real binary. That is the price of a bare name, and it is
cheap precisely because putting PHP on the VM is a thing we have decided
not to do.

Precise ordering, since "highest priority" is not quite literal:
`bootstrap/50-build.sh` writes `PATH="$HOME/.local/bin:/opt/mpd/bin:$PATH"`,
so shims outrank every system path but sit *below* `~/.local/bin`. A
binary the dev drops there by hand still wins — an escape hatch, if an
odd one.

### Day-one shims

- **`php`** — bare.

Only that one. `mudev` was on this list until Change 5 made it a
VM-native binary at `/opt/mudev` — there is nothing to forward to.

Nothing else on day one. Every shim permanently claims a name on the VM's
PATH, so the list should grow on demand rather than up front — and
`mpd run <anything>` already covers the long tail without a shim.

Shims inherit the project-context constraint: `php` outside
`/srv/projects/<name>/` fails the same way `mpd run` does. The error must
name the shim the user actually typed, not `mpd run`, or the message
points at a command they never invoked.

The future candidates are knowable, though: mdc's `bin/` is almost exactly
mpd's `assets/runtimes/php/project_types/moodle/tools/` (`behat`,
`behat-init`, `grunt`, `phpunit`, `phpunit-init`, `mpci`, …). Those bare
names are all safe by the rule above, since none of them exist on a plain
Debian VM.

### Why not a plain `podman exec` wrapper

The mandatory architecture rule says `go/internal/podman` is the single
gateway for container operations and `go/internal/exec` the only package
that runs host commands. A shell wrapper calling `podman exec` directly
would put podman knowledge outside that gateway. Routing through `mpd run`
keeps the rule intact, so this is an **extension** of the rule, not an
exception to it:

> A VM-side wrapper may forward a command into a runtime, but only via
> `mpd`. It never invokes podman itself.

This belongs in `ARCHITECTURE.md` §7 alongside the verb/tool contract, as
a third category: verbs (host-side Go), tools (in-runtime executables),
and shims (VM-side forwarders that are neither).

Recursion note: the VM's `php` execs `mpd run -- php`, which resolves
`php` on the *container's* PATH — a different machine, so no
self-recursion. This is the one place a bare shim needs care: the shims
must never end up on a container's PATH, or a shim would forward to
itself. They live in `/opt/mpd/bin/`, which is bind-mounted into every
runtime at the same path, so keeping them off the container PATH is a
real constraint rather than a theoretical one. (`/srv/tools/*` is what
runtimes put on PATH; `/opt/mpd/bin` is not among them.)

## Change 3 — retire fileaccess

The fileaccess service does two jobs. The mount kills one and relocates
the other.

**Job A — data-volume exec target.** Per `SetupFileAccess`'s own comment,
mpd reaches `/srv` by exec'ing into this container rather than
bind-mounting the volume on the VM. Once `/srv` is mounted, this
disappears: `VolumeRead`, `VolumeWrite`, `VolumeExec`, `VolumeMkdirAll`,
`VolumeRemoveAll` and `ensureDataVolumeDirectories` all become plain
filesystem operations. That's **17 call sites across 9 files** — mostly
`project.go` (4 reads, 4 writes), plus `runtime/cache.go`,
`project/rescan.go`, `cli/{status,show,runtime,project,db,action}.go`,
`db/db.go`.

One wrinkle: `VolumeRemoveAll` is documented as deleting *as root*, and
`/srv/dbs` is deliberately root-owned. Those become privileged host
operations and must route through `go/internal/exec`, not `os.RemoveAll`.

**Job B — SFTP endpoint for the host.** Its own IP and DNS name,
persistent host keys under `state/fileaccess/hostkeys/` so `known_hosts`
survives rebuilds, the VM user's `authorized_keys` mounted RO, and a
`.profile` that drops interactive sessions into `/srv/backups`. This does
not become unnecessary — it **moves to the VM's own sshd**, which the host
already connects to for the `mpd` CLI. One less host key, one less DNS
name, one less container.

The endpoint is also *worse* than the VM's sshd on reachability, which
settles it: fileaccess listens only on the internal podman network with no
`-p` mapping, so a host reaches `fileaccess.service.<zone>` only once the
static route is configured. The VM's sshd needs no route — it is how the
developer already gets in — so file access over it works in both modes.

### Two steps, not one

Job B can go **now**; job A cannot go until Change 1 lands. Nothing uses
the SFTP endpoint yet, so removing it is unblocked and independent of
everything else in this proposal:

1. **Now — strip the endpoint, keep the container.** Delete sshd and
   `sshd_config` from the image, the host-key persistence
   (`vm.FileAccessHostKeysDir`), the `authorized_keys` mount, the
   `.profile` that lands sessions in `/srv/backups`, the portal tile
   (`assets/services/portal/www/index.php:419`), and the service-registry
   entry with its DNS name. With no listener the container needs no
   address on `mpd-internal` at all, which frees `net.HostFileaccess`
   early. What remains is an unexposed helper whose only job is being a
   `podman exec` target — an implementation detail, not a service. Bump
   `fileaccessRevision` so existing containers get rebuilt instead of
   surviving with sshd still running.
2. **With Change 1 — delete the container.** The `Volume*` calls become
   filesystem operations and the last reason for it disappears.

Step 1 earns its own commit: it removes a listening SSH daemon, a
persistent host key and an `authorized_keys` mount from the system without
waiting for the mount work, and it shrinks step 2 to a mechanical
deletion.

Eventual removals: `assets/services/fileaccess/`,
`go/internal/service/fileaccess.go`, the registry entry in `service.go`,
the `Volume*` exec plumbing and `FileAccessContainer` in `podman.go`,
`vm.FileAccessHostKeysDir`.

`net.HostFileaccess` (octet 5) is **retired, not reused.** A future
service taking `.5` would collide with stale DNS and `known_hosts` entries
on VMs that predate this change. Leave it in `net.go` as a reserved
constant with a comment.

### Security note

Today an SFTP session from the host lands in a container with only `/srv`
mounted. Afterwards the same key reaches the whole VM. It's the same
person with the same key, and the VM is already their `mpd` shell, so this
isn't a real boundary being removed — but it is a documented one, and
`SECURITY.md` should say so explicitly rather than let it lapse silently.

## Change 4 — simplify `mpd create`

Today: `mpd create <project> [--type X] [--git-repo U] [--git-branch B]
[--git-depth N]`.

**Drop the git flags entirely.** They exist because the VM could not
reach `/srv` — cloning had to be proxied through a container, which is
also why `ProjectCreate` carries `gitHost()` and `waitForHostResolves()`
(polling until the git host resolves inside the container, because a
freshly created runtime has just had dnsmasq restarted under it) and why
the clone needs `--progress` to work around a broken isatty check through
`podman exec`. All of that is scaffolding around a limitation the mount
removes. Afterwards:

```
mpd create moodle501
cd /srv/projects/moodle501
git clone https://github.com/moodle/moodle.git .
```

The clone runs on the VM, as the VM user, with their own SSH agent and
credentials — no proxying, no resolver race, no shallow-clone caveat to
document. `gitHost` and `waitForHostResolves` have no other callers and
die with the flags.

**Make the project name optional, and keep `--type` as a flag:**

```
mpd create [<project>] [--type moodle|astro|bare|cftunnel]
```

Run from inside `/srv/projects/xyz/`, `mpd create` means `mpd create
xyz` — the same resolver `mpd run` uses. That is the natural VM workflow
now: make the directory, clone into it, then register it.

**This is why `--type` stays a flag.** A second positional cannot work:
at create time the project does not exist yet, so nothing can
disambiguate `mpd create moodle` — is `moodle` the name of a new project
or the type of a cwd-derived one? Both readings are legal (`moodle`
passes `validProjectName`, and only CLI *verbs* are reserved names), and
no amount of lookup resolves it, because the whole point is that the
project isn't registered. Keeping the type in a flag makes the single
positional unambiguously the project name, which is the only reading
compatible with cwd inference.

An explicit positional always wins over cwd. Outside `/srv/projects/`
with no positional, error.

`--type` validates against `AllProjectTypes()` and rejects anything else
with the valid list in the message — an unknown type should not silently
fall through to `moodle`, which is what the current code does.

Type inference from the project name stays exactly as it is
(`DetectTypeFromName`: exact type name, else `nameSuffix` match, else
`moodle`); `--type` is simply an explicit override for when the name
doesn't imply the right thing.

This composes with the parked `MPD_RUNTIME`-in-`mpd.env` work rather than
competing with it: the resolved type still picks the runtime at create
time, and `mpd.env` remains free to become the source of truth for
placement afterwards.

### The one caller: `bin/demo`

`bin/demo:51-54` is the only thing in the repo that passes the git flags
(`--git-repo`, `--git-branch`, `--git-depth=1`, wrapped in a
`GIT_CONFIG_*` incantation to silence detached-HEAD advice). It must be
updated in the same commit that drops them — a clean cut is only clean if
the sole caller moves with it. Post-mount the replacement is ordinary
shell: `mkdir`, `git clone --depth=1 -b "$TAG"`, then `mpd create`.

`demo` is slated for a redesign on top of mudev, at which point recipes
replace the hardcoded clone entirely. The interim edit should stay
deliberately small for that reason.

**Unrelated bug the mount fixes.** `bin/demo:42` guards with
`[ -d "/srv/projects/$PROJECT" ]` — but `demo` runs on the VM, where
`/srv` does not currently exist. The test can never be true, so the
"already exists → just start it" branch is dead code and re-running
`demo moodle v5.2.0` falls through to `mpd create` and fails with
"Project already exists." Change 1 fixes it with no edit to `demo` at
all. Worth noting that the script was written assuming a VM-side `/srv`:
the mount is the model the code already expected.

Docs and completion: `CLI_BEHAVIOR.md:151` documents all four flags,
`USAGE.md:107` uses `--git-repo`/`--git-branch` in the worked example, and
`complete.go:146` offers all four as `verbArgs` — which should keep
`--type=` (completing to project type names) and drop the three git
flags. `create` also becomes the first verb whose project argument is
optional, which `cobra.ExactArgs(1)` currently forbids.

## Change 5 — `/srv/extra/` and VM-side mudev

`/srv/extra/` is a new slot on the data volume for **third-party index
repos that mpd and other tools read**: plugin lists, recipes, and the
dev's own private recipes. mpd owns the slot and (eventually) the
manifest contract; it does not own the contents. Same ownership model as
`/var/lib/mpd/skel/`.

`docs/ROADMAP.md` already describes the tenants — "`mdl-plugins` /
`mdl-recipes` — companion index repos … plain git repos of static
manifests that the demo, mpd, and composer read". That entry is the
canonical owner of the idea and should gain a line naming this location.

`mpd --vm-setup` provisions it, all VM-side:

```
/srv/extra/mdl-plugins  ← https://github.com/mutms/mdl-plugins.git
/srv/extra/mdl-recipes  ← https://github.com/mutms/mdl-recipes.git
/srv/extra/dev-recipes  ← created empty (private; the dev clones their own)
/opt/mudev              ← https://github.com/mutms/mudev.git, built here
```

The point is **availability before any runtime exists**. mudev becomes a
VM-native tool usable at project-creation time, not something that has to
be installed into a php runtime first — which is the same reordering
Change 4 makes for `create` and the parked `MPD_RUNTIME` work makes for
placement.

Consequences:

- **`mudev-install` and `mudev-install-dev` are deleted.** Both are
  superseded by automatic provisioning. Push access is a one-off
  `git remote set-url` per VM, and the private `dev-recipes` is a one-off
  clone into the empty slot — cheaper than maintaining two parallel
  install scripts. (Both tools carry a SUPERSEDED note until then.)
- **The `mudev` shim comes off the day-one list.** mudev is native on
  the VM; there is nothing to forward. `php` is the only day-one shim.
- `/srv/extra` joins the directory lists in `runtime-base/bootstrap.sh`,
  `services/fileaccess/entry.sh`, and `ensureDataVolumeDirectories`
  (already done — the slot is inert until something populates it).

### Sequencing

This change depends on Change 1 and cannot precede it: there is no
VM-side `/srv` to clone into until `srv.mount` exists. Within
`--vm-setup`, the mount step must run before the clone step. Deleting the
two install tools comes last, after provisioning works — deleting them
first would leave no way to get mudev at all.

### Network and credentials

**A failed clone is fatal**, like every other step. `--vm-setup` already
requires internet: it builds the fileaccess and adminer images, both of
which `FROM docker.io/library/debian:trixie` and `apt-get install` inside
the build. Cloning from github adds no new class of dependency, so it
gets no special-case leniency.

**Anonymous HTTPS only — `--vm-setup` must never require an SSH key.**
Setup has to work on a fresh VM before the dev has arranged agent
forwarding or dropped a key, so every remote it touches is public and
unauthenticated. That is also what removes the reason for the
public/private split in the old install tools: with no SSH in the setup
path, there is one provisioning path, not two.

Push access and the private repo stay manual, one-off, and outside setup:

```
git remote set-url origin git@github.com:mutms/mdl-recipes.git   # per repo, per VM
git clone git@github.com:mutms/dev-recipes.git /srv/extra/dev-recipes
```

If that gets tedious it deserves a command — one that switches the
remotes, clones the private repo into the empty slot, and fails early
with an actionable message when SSH auth isn't working (the preflight the
old `mudev-install-dev` had). **That command belongs in mudev, not mpd.**
It is about mudev's repos and mudev's contributor workflow; shipping it in
`/opt/mpd/bin/` would rebuild the coupling `/srv/extra` exists to remove.

## Migration

For an existing VM, `mpd --vm-setup` does all of it: writes and starts
`srv.mount`, then removes the fileaccess container and image. It should
print a note that the SFTP endpoint has moved to the VM, since the user
must drop a `known_hosts` entry and repoint any saved PhpStorm/Cyberduck
connection. Nothing on the data volume changes — same files, same
ownership, new view.

## Docs to update

- `AGENTS.md` — "Fixed in-VM paths": `/srv/` is no longer
  containers-only.
- `ARCHITECTURE.md` — §7 gains the shim category and the wrapper rule;
  networking summary drops fileaccess.
- `CLI_BEHAVIOR.md` — `mpd run`, including the non-project grammar.
- `USAGE.md` — VM-side workflow; fileaccess → VM sshd.
- `NETWORKING.md`, `SECURITY.md`, `docs/README.md` — fileaccess removal.
- `assets/services/portal/www/index.php` — drops the fileaccess tile.

## Non-goals

- **Not** converting `/srv` from a named volume to a host directory
  bind-mounted into containers. That's the more honest architecture and
  worth revisiting, but it needs a data migration and a rewrite of the
  `/srv` ownership story. The mount gives us the whole benefit now at a
  fraction of the risk.
- **Not** specifying `MPD_RUNTIME` in `mpd.env` as the placement source of
  truth. This proposal *unblocks* it; the create-flow inversion deserves
  its own design.
- **Not** adding cwd inference to `start`/`stop`/`show`/`configure`
  (motivation 2), beyond `create` which needs it here. Same resolver, but
  each verb has its own questions — `delete` in particular, where
  inferring the project from the directory you are standing in deletes
  that directory out from under you. Worth doing, worth doing separately.

## Open questions

1. ~~Should `mpd run` accept `--runtime <name>` for commands with no
   project context?~~ **Settled:** no project, no run. An escape hatch
   can be added later if a real need shows up; it isn't one now, and
   leaving it out keeps the command's meaning unambiguous.
2. TTY allocation: infer from stdin, or an explicit `-t` like `podman
   exec`?
3. ~~Which commands get shims on day one?~~ **Settled:** `php` only,
   bare, under the naming rule above. (`mudev` dropped off — Change 5
   makes it VM-native.)
4. Does anything besides the host's SFTP client actually use the
   fileaccess DNS name? A grep says the portal page links it; worth a
   check for muscle memory in personal scripts before it disappears.
5. ~~`mpd create`'s positional: type, runtime, or either?~~ **Settled:**
   project type only.
6. ~~Is dropping the `mpd create` git flags worth a deprecation period?~~
   **Settled: clean cut.** The only in-repo caller is `bin/demo`, updated
   in the same commit; `demo` is being redesigned on mudev anyway.
