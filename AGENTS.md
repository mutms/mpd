# AI Agent Starting Point

Neutral bootstrap document for AI agents working in this repository. Single
source of truth; `CLAUDE.md` imports this file via `@AGENTS.md` so Claude
Code, Codex, Aider, and other tools that read AGENTS.md natively all see
the same instructions.

## What mpd is

`mpd` (Moodle Plugin Development) is a local development environment for
Moodle plugin work, built around reproducible runtime containers, local DNS,
and HTTPS endpoints. It has three user-facing modes, distinguished by where
the user sits and where `mpd` runs:

- **Sandbox VM** — full GNOME desktop *inside* the VM, `mpd` runs in
  the VM. User installs Ubuntu 26.04 desktop in any hypervisor,
  snapshots, runs `setup/sandbox/take-over-sandbox-vm.sh` inside the
  VM. Host stays untouched.
- **mpd-machine** — automated headless Debian Trixie VM driven by a
  matched-host bootstrap (UTM on macOS, libvirt/KVM on Ubuntu,
  Hyper-V on Windows). User stays on their host: host browser visits
  `*.mpd.test` directly via a static route + DNS resolver + CA trust;
  host terminal SSHes into the VM to use the `mpd` CLI.
- **mpd-desktop** — `mpd` is a native macOS binary in the user's
  local Terminal (no SSH). Podman Desktop manages a Linux container
  machine in the background; macOS reaches the containers via a
  WireGuard tunnel.

**Implementation note:** internally there are two code paths —
`mpd/Environment/Desktop/` (mpd-desktop) and `mpd/Environment/Machine/`
(both mpd-machine and the sandbox flavor). Sandbox is `PlatformKind.sandbox`
under the Machine code path; from the user's perspective it's a distinct
mode, from the codebase's perspective it shares Machine plumbing.

Read `README.md` first for the user-facing overview.

## Fixed source checkout path

- Required path for desktop contributor workflow: `~/Developer/mpd`.
- Runtime path checks are strict — `mpd` enforces it. Do not propose alternate
  source locations.

## Code layout

The Swift binary lives under `mpd/`. Each subdirectory is a `Mpd.<X>` namespace:

- `mpd/CLI/` — command handlers, status rendering, completion (`Mpd.Completion`)
- `mpd/Core/` — assets path, state files, persistent identity
- `mpd/Environment/Desktop/` — macOS + Podman Desktop integration
- `mpd/Environment/Machine/` — Linux VM integration
- `mpd/Runtime/` — runtime/project orchestration, sidecar reconciliation
- `mpd/Service/` — always-on infra services (dnsmasq, portal, adminer,
  fileaccess; wireguard on desktop only)
- `mpd/TUI/` — interactive terminal UI
- `mpd/Util/` — Podman shell-out gateway (`Mpd.Podman.*`) and other utilities
- `mpd/Mpd.swift` — namespace root (open this file to see the full API surface)
- `mpd/main.swift` — CLI entry, ArgumentParser dispatch

Runtime/project-type behavior + service container assets live under `assets/`:
- `assets/machine/` — VM-level assets deployed to the mpd-machine VM itself
  (e.g. `motd` — installed to `/etc/motd` by provisioning scripts)
- `assets/runtimes/<runtime>/...` — runtime definitions, project types, tools
- `assets/services/<n>/...` — always-on infra services
- `assets/sidecars/<n>/...` — per-runtime-pod sidecars
- `assets/completions/` — shell completion shims
- `assets/templates/` — per-developer template (`mpd-user.env`); runtime
  and type *defaults* live next to their owners under
  `assets/runtimes/<rt>/mpd-defaults.env` and
  `assets/runtimes/<rt>/project_types/<type>/mpd-defaults.env`

## Canonical docs map

Topic owners — update the owning file for a topic instead of duplicating
across docs.

- `README.md` — project overview and entry point
- `docs/README.md` — documentation index
- `docs/CLI_BEHAVIOR.md` — CLI behavior contract (both modes)
- `docs/ARCHITECTURE.md` — repo architecture, mode split, networking summary, **verb/tool contract (§7)**
- `docs/VISION.md` — product vision (origin lineage + design principles)
- `docs/ROADMAP.md` — committed near-term work
- `docs/desktop/README.md` — what mpd-desktop is, release scope
- `docs/desktop/USAGE.md` — desktop workflows
- `docs/desktop/NETWORKING.md` — desktop networking model (WireGuard)
- `docs/desktop/SECURITY.md` — desktop security model
- `docs/machine/README.md` — what mpd-machine is, status, scope
- `docs/machine/USAGE.md` — machine workflow
- `docs/machine/NETWORKING.md` — machine networking (static route, no WG)
- `docs/machine/SECURITY.md` — machine security model
- `setup/macos-utm/README.md` — UTM-on-macOS automation + recovery
- `setup/ubuntu-kvm/README.md` — Ubuntu host + libvirt/KVM automation
- `setup/windows-hyperv/README.txt` — Windows host + Hyper-V automation
- `setup/sandbox/README.md` — graphical "live in the VM" Ubuntu sandbox

There is no `docs/machine/platform/*` tree — earlier drafts imagined per-OS
platform docs, but per-OS detail lives inline in NETWORKING.md instead.

## Mandatory architecture rule

`Mpd.Podman` is the single shared gateway for container operations. Direct
host-OS command execution is allowed only inside `mpd/Environment/Desktop/`
and `mpd/Environment/Machine/`. Other layers (CLI, Runtime, Service, Core)
must not shell out directly — they request via Podman or environment APIs.
Full rule + review checklist in `docs/ARCHITECTURE.md` §"Mandatory Constraint".

## Mandatory privilege rule

Applies to runtime containers, the mpd-machine VM, and the fileaccess
service — anywhere mpd ships shell code for a host with a dev user
plus passwordless sudo.

1. **Scripts run as the dev user.** Every shell asset under
   `assets/` and `mpd-machine/` is invoked as the dev user. The
   orchestrator (Swift's `podman exec -u <user>`, host-side ssh, etc.)
   is responsible for setting that identity at exec time. Scripts do
   not change identity themselves.
2. **`sudo` is for individual privileged commands only**, executed
   from inside a script that runs as the dev user. Allowed shapes:
   `sudo apt-get …`, `sudo install -d /opt/mpd`, `sudo systemctl …`,
   `sudo chown -R "$(id -un):$(id -un)" /opt/mpd`, `sudo tee
   /etc/profile.d/foo.sh`. `chown` is fine when scoped to
   dev-user-owned territory (`/opt/mpd`, `/srv/`).
3. **Never wrap a whole script in `sudo`.** No
   `sudo bash <whatever>.sh`. If a script needs many privileged ops,
   the script itself runs as the dev user and sudo's each one. The
   orchestrator never invokes a provisioning-shaped script as root
   (only `bootstrap.sh` is, by exception — see below).
4. **Never identity-switch to a non-root user.** All of the
   following are forbidden — anywhere in mpd shell code, no
   exceptions: `sudo -u <user>`, `runuser -u <user>`, `runuser
   <user>`, `su - <user>`, `su <user> -c …`. If you find yourself
   reaching for one, the orchestrator is invoking the script with
   the wrong identity — fix that, don't switch in-script.

**Single bootstrap exception.** The dev user must exist before
rule (1) can hold. Exactly one root-context script,
`assets/runtime-base/bootstrap.sh`, runs before the dev user exists
and creates it (along with sudoers, sshd, /etc/mpd identity, /srv
layout). The orchestrator (`Mpd.Runtime` provisioning step) is the
only caller. After it returns, phase 2 — `assets/runtimes/<rt>/build.sh`
— runs as the dev user via `podman exec -u <user>`. Nothing else
may invoke a script as root.

The boundary guard `make check-privilege-boundary` greps for the
forbidden shapes in (3) and (4) — keep it green.

## Change discipline

- Keep changes scoped to the requested task. No drive-by refactors.
- Update affected docs when moving/renaming files.
- Prefer additive asset changes for runtime/project-type behavior; reserve
  Swift edits for control-plane, state, networking, and orchestration.
- Prefer deterministic behavior over convenience fallbacks.
- Avoid cross-file doc duplication; link to canonical owners.
- For shell completion, edit `mpd/CLI/Complete.swift` — the shims under
  `assets/completions/` are stable forwarders and rarely need to change.
- **Each `setup/<name>/` directory must stay
  self-contained** — it's released as a small standalone bundle (a
  handful of `.sh` / `.ps1` / `.cmd` plus a README) and dropped onto a
  fresh host before the mpd repo is cloned. Scripts in there may only
  reference files inside the same directory plus standard host tooling
  and what they pull at runtime (`git clone`). Do **not** reach into a
  sibling platform directory or anywhere else in the repo from
  bootstrap-stage code; duplicate small helpers instead. See
  [`setup/README.md`](setup/README.md)
  for the full rule.

## Authoring verbs and tools

Verbs (host-side, surfaced as `mpd <verb> <project>`) and tools
(in-runtime, on PATH) are the extension surface for runtime + project-
type functionality. The contract — what a verb is vs. a tool, naming
conventions, PATH precedence, privilege model, idempotency — lives in
[`docs/ARCHITECTURE.md` §7](docs/ARCHITECTURE.md). Read that first;
this section is the "how to write one" follow-up.

### Decide: verb or tool?

> A capability is a **verb** if and only if it does work that the
> runtime container can't do for itself. Otherwise it's a **tool**.

Almost everything is a tool. The verb set is fixed and tiny — `create`,
`configure`, `start`, `stop`, `delete`, `show` — all Swift, all in the
control plane. Project-type-specific functionality (cron, phpunit,
composer, …) is exposed inside the runtime container where SSH sessions
and AI agents run; you reach it via PATH after `ssh user@<runtime>.runtime.mpd.test`.

If you find yourself writing a verb whose body is essentially
`podman exec <container> <tool>`, you're writing a redundant verb.
Write only the tool.

### Adding a verb (rare)

Verbs are **Swift**, in `mpd/Runtime/`, `mpd/CLI/`, etc. The dispatch
table is `Mpd.Project.dispatch` in `mpd/Runtime/Project.swift`; the
public verb set is `projectVerbs` in `mpd/main.swift`.

To add a new verb:

- Add a Swift handler (a static func on `Mpd.Project`) in the
  appropriate file (`ProjectLifecycle.swift` for lifecycle-shaped
  things, `ProjectOperations.swift` otherwise).
- Add the verb name to `projectVerbs` in `mpd/main.swift`.
- Add a dispatch case in `Mpd.Project.dispatch`.
- Update `Mpd.Project.showHelp` so the per-project `--help` lists it.
- Update `mpd/CLI/Complete.swift` for shell completion (verb name +
  any flag suggestions in `verbArgCandidates`).
- Update `docs/CLI_BEHAVIOR.md` and the `Day-to-day commands` section
  in `docs/desktop/USAGE.md` / `docs/machine/USAGE.md` if it belongs
  in the daily surface.

Global flags (`mpd --foo`) live in `mpd/main.swift` (the
`GlobalCommand` ParsableCommand) plus a handler under
`mpd/CLI/CommandHandlers/`.

### Adding a tool

A tool is a single executable script under one of three locations,
chosen by scope:

- `assets/runtime-base/tools/` — works in **any** Trixie-based runtime
  (php, node, trixie, future ones). bootstrap.sh symlinks these into
  `/srv/tools/_base/` and adds that dir to PATH for every login shell.
  Examples: `claude-install`, `node-install`.
- `assets/runtimes/<runtime>/tools/` — runtime-wide. The runtime's
  `build.sh` symlinks these into `/srv/tools/<runtime>/` and adds that
  to PATH. Examples (php): `composer-install`, the `php` wrapper.
- `assets/runtimes/<runtime>/project_types/<type>/tools/` — only
  available when a project of that type is in the runtime. Symlinked
  into `/srv/tools/<type>/`, which sits highest on PATH so a type
  tool wins over a runtime or base tool of the same name.

Skeleton (any of the three locations):

```bash
#!/bin/bash
set -euo pipefail
# Tool: <one-line description>.
# Runs as the dev user inside the runtime. May use sudo freely
# (see ARCHITECTURE.md §7 "Privilege model").

# Walk up from $PWD to find the project root (presence of mpd.env).
PROJECT_DIR="$PWD"
while [ ! -f "$PROJECT_DIR/mpd.env" ] && [ "$PROJECT_DIR" != "/" ]; do
    PROJECT_DIR="$(dirname "$PROJECT_DIR")"
done
if [ ! -f "$PROJECT_DIR/mpd.env" ]; then
    echo "Not inside a project tree (no mpd.env found)" >&2
    exit 1
fi

# Load the four-layer MPD_* env (runtime defaults → type defaults →
# $HOME/mpd-user.env → project mpd.env). source-mpd-env.sh uses a
# whitelist parser, so a malicious project mpd.env cannot inject code.
PROJECT_NAME="$(basename "$PROJECT_DIR")"
. /mnt/assets/runtime-base/lib/source-mpd-env.sh

# Do the work. Idempotent if -install or -init.
...
```

Tools are bind-mounted at `/mnt/assets/runtimes/<rt>/...`, symlinked
into `/srv/tools/<type>/`, and added to PATH at runtime provision time.
Edits on the host (or VM) are immediately visible inside the runtime —
no rebuild step.

#### Naming

- **Bare name** for upstream-known tools (`composer`, `php`,
  `phpunit`).
- **`mdl-` prefix** for Moodle-specific operations whose bare name
  would collide with system commands or be too generic (`mdl-cron`,
  `mdl-cache-purge`, `mdl-install`).
- **`-install` suffix** for "fetch the binary itself" (runtime-wide,
  one-shot, idempotent). Drops the binary into runtime FS — typically
  `/usr/local/bin/` — never under `/srv/`.
- **`-init` suffix** for "ready a project for the tool"
  (project-scoped, idempotent, may run many times across projects).

#### Idempotency (required)

`-install` tools must no-op cleanly when the target binary already
exists. `-init` tools must no-op cleanly when the project is already
initialized. Orchestrators call dependencies blindly without
guard-checking, so each tool guards its own work:

```bash
# composer-install pattern
if [ -x /usr/local/bin/composer ]; then exit 0; fi
# ... fetch + verify + install ...
```

```bash
# phpunit-init pattern
if mysql -u root -e "USE phpu_${PROJECT}_db" 2>/dev/null; then exit 0; fi
# ... drop-and-recreate ...
```

#### Wrapper tools — avoid PATH recursion

Tools whose bare name overrides a system binary (e.g. `tools/php`
shadowing `/usr/bin/php`) must `exec` the upstream binary by absolute
path. Otherwise the wrapper recurses into itself:

```bash
# WRONG — recurses
exec php "$@"

# RIGHT — absolute path
exec /usr/bin/php8.4 "$@"
```

Look up the resolved version (e.g. from
`/srv/meta/<project>/project.json`) and exec the matching
`/usr/bin/phpX.Y` directly.

#### Privilege

Tools run as the dev user with passwordless `sudo` available. **Use
`sudo` *inside* the tool** for the operations that need root —
the dev/AI never types `sudo toolname`:

```bash
# correct — internal sudo on the privileged op:
sudo install -m 755 "$TMPDIR/binary" /usr/local/bin/binary
sudo systemctl restart php8.4-fpm

# correct — caller invokes the tool bare:
$ composer-install
```

Don't write tools that self-elevate (`if [ uid != 0 ]; then exec sudo
"$0"; fi`) — running the entire script as root via wholesale
escalation breaks least-privilege. Don't expect the caller to type
`sudo toolname` either — sudo's `secure_path` doesn't include
`/srv/tools/`, so the bare invocation through sudo would fail "command
not found." Internal sudo on specific operations is the right shape.

#### Testing checklist for a new tool

1. Rebuild the runtime: `mpd --runtime-delete <rt>` then recreate via
   project create (or `mpd --runtime-create=<rt>`).
2. SSH in: `ssh user@<rt>.runtime.mpd.test`.
3. `which <new-tool>` resolves to the expected path under `/srv/tools/`.
4. Run with no project context (negative test) — should fail
   gracefully with an actionable message.
5. `cd /srv/projects/<project>/` and run again — should succeed.
6. **Re-run immediately** (the idempotent path). Exits 0, no
   duplication.
7. For `-install` tools: confirm the binary lands under `/usr/local/bin/`
   or similar runtime FS, never `/srv/`.

#### What to update when adding a tool

- The tool itself (executable, `chmod +x`).
- If the tool deserves dev-facing mention: add a one-line entry under
  "Tools available inside the runtime" in `docs/desktop/USAGE.md` and
  `docs/machine/USAGE.md`.
- If it replaces an existing verb (verb→tool migration): delete the
  obsolete verb files and update any host-side callers that referenced
  the verb by name.

## Pre-release validation

**Build / static checks** (run after any code or asset change):
- `make install` (writes `bin/mpd`)
- `make check` — runs the boundary guards:
  - `check-hostexec-boundary` — fails if `Process(...)` appears
    outside `mpd/Environment/{Desktop,Machine}/HostExec.swift`.
  - `check-mpdenv-source-boundary` — fails if any shell asset under
    `assets/` or `mpd-machine/` raw-`source`s an `mpd*.env` file
    (everything must go through `source-mpd-env.sh`'s whitelist parser).
- skim affected docs for stale path / link references when moving or
  renaming files.

**Desktop non-destructive checks** (rerun freely — all idempotent):
- `mpd --setup`, `mpd --start`, `mpd --stop`, `mpd --uninstall`

**Machine throw-away-VM smoke checks:**
- fresh VM via `setup/macos-utm/create-vm.sh [<suffix>]`
- `mpd --setup`, `mpd --start`, `mpd --status`
- optional: `mpd create/start/stop <project>` end-to-end including HTTPS hit
- `mpd --stop`, `mpd --uninstall --yes`
