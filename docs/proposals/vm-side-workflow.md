# Proposal: the project you're standing in, and a recipe-driven `demo`

Status: draft, 2026-07-21. Delete this file when it ships — the code and
the canonical docs become the record.

This is what remains of a larger proposal. The substrate it depended on
has landed: `/srv` is bind-mounted on the VM by `srv.mount`, the
fileaccess container is gone (mpd reads and writes the volume as ordinary
files via `go/internal/srv`), `/srv/extra/` holds the catalogues, and
mudev is built on the VM and bind-mounted read-only into every runtime.

`mpd run` has since landed; two things remain.

## 1) `mpd run` — shipped

```
mpd run [--] <command> [args...]
```

Runs a command inside the runtime that owns the project you are standing
in, with your working directory forwarded verbatim — correct without
translation, because `/srv` is the same tree at the same path on the VM
and in every container.

Implemented in `go/internal/cli/run.go`, with `podman.ExecAttached` for
the stdin-connected exec and `cli.ExitError` carrying the child's status
out through `main`. Flag parsing is disabled for the verb so the child's
own flags survive; a TTY is allocated only when stdin is one.

**No VM-side shims.** An earlier draft proposed a `php` shim in
`/opt/mpd/bin/` forwarding through this verb. Dropped:
`mpd run php admin/cli/install_database.php …` reads fine as it is, and a
bare `php` on the VM would forward silently from the wrong terminal
instead of failing with `command not found`. Not claiming the name keeps
that signal, and `mpd run <anything>` already covers composer, phpunit,
mdl-cron and the rest with nothing to add per command. The tools
themselves stay where they belong: inside the runtime, on PATH from the
assets tree.

## 2) The project you are standing in

One resolver, used by `mpd run` and by `mpd create`.

**`/srv/projects/<name>/` or a subdirectory of it — nowhere else.**
Outside that tree there is no project, and without a project there is no
runtime to act on. Refuse with an actionable message rather than
guessing.

Resolution:

- Normalise `$PWD` (absolute, symlinks resolved) and require it to be
  `/srv/projects/<name>` or below. Normalising first is what stops `../..`
  and symlink games from walking out of the tree.
- Look up `<name>` in `projects.json`. Not registered → error. That file
  carries `RuntimeName`, which is the answer actually needed.

This is **not** the in-runtime tools' rule (walk up to `mpd.env`, take the
basename). Tools use that because a runtime container cannot see
`projects.json` — the state dir is not mounted into runtimes — so
`mpd.env` is their only local evidence. On the VM the registry is right
there, and a path check has two advantages: it cannot be spoofed by a
stray `mpd.env` elsewhere on the VM, and it still resolves a project whose
`mpd.env` is missing or not yet written.

### `mpd create`

```
mpd create [<project>] [--type moodle|astro|bare|cftunnel]
```

Run from inside `/srv/projects/xyz/`, `mpd create` means `mpd create
xyz` — the natural VM workflow now that the directory is right there:
make it, clone into it, then register it.

**This is why `--type` stays a flag.** A second positional cannot work:
at create time the project does not exist yet, so nothing can
disambiguate `mpd create moodle` — is `moodle` the name of a new project
or the type of a cwd-derived one? Both readings are legal (`moodle` passes
`validProjectName`, and only CLI *verbs* are reserved), and no lookup
resolves it, because the whole point is that the project is not
registered. Keeping the type in a flag makes the single positional
unambiguously the project name, which is the only reading compatible with
cwd inference.

An explicit positional always wins over cwd. Outside `/srv/projects/`
with no positional, error. `--type` validates against `AllProjectTypes()`
and rejects anything else with the valid list in the message — an unknown
type must not silently fall through to `moodle`, which is what the
current code does.

`create` becomes the first verb whose project argument is optional, which
`cobra.ExactArgs(1)` currently forbids.

### Already decided, lands with `create`

The `--git-repo` / `--git-branch` / `--git-depth` flags go, in a clean
cut. They exist only because the VM could not reach `/srv`; now the clone
is ordinary shell on the VM, with the dev's own credentials. Their removal
also deletes `gitHost()` and `waitForHostResolves()` (polling until the git
host resolves *inside the container*, because a freshly created runtime
has just had dnsmasq restarted under it) and the `--progress` workaround
for `podman exec`'s broken isatty check. Neither helper has another caller.

`bin/demo:51-54` is the only caller and must be updated in the same
commit; it is slated for a redesign on top of mudev recipes, so the
interim edit should stay small. `docs/USAGE.md:106` still shows the flags
in its worked example.

## 3) `demo`, reworked on mudev

```
demo <recipe> [<projectname>]
```

Two forms, one script:

```
demo moodle/release/4.5.12 moodle45                        # nothing exists yet
cd /srv/projects/moodle45 && demo moodle/release/4.5.12    # tree already cloned
```

The optional argument is **last**, so position alone decides what each
token is — first is always the recipe, second always the project name.
No name-vs-recipe grammar rule to document, unlike `mpd create`'s single
positional. Omitted, the project name comes from the cwd (§2), so the
second form is the by-hand sequence collapsed:

```
cd /srv/projects/moodle45
mudev clone moodle/release/4.5.12
mpd create && mpd configure && mpd start
```

This is also what makes §2's optional positional structural rather than
convenience: `demo` passes a name explicitly in the first form and relies
on cwd in the second, and gets one code path for both.

`demo` currently hardcodes a flavour and a tag (`demo moodle v5.2.1`),
clones Moodle from GitHub by tag, and installs it. mudev already does the
assembly half properly — a recipe names a Moodle branch plus a plugin set
plus config — so `demo` should stop knowing how to build a tree and start
naming which tree it wants.

Resolution is unambiguous, unlike `mpd create`'s positional: the
filesystem answers it. If the token resolves to an existing file, it is a
recipe file; otherwise it is a name looked up in
`/srv/extra/mdl-recipes/`. Pin the precedence explicitly (path wins) so a
recipe sharing a name with a file in the cwd does not surprise anyone.

What `demo` keeps: the `mpd create` → `configure` → `start` sequence and
printing the URL and credentials at the end. What it loses: the flavour
table, the tag argument, and the `--git-*` flags removed in §2.

**Bug the mount already fixed.** `bin/demo:42` guards with
`[ -d "/srv/projects/$PROJECT" ]`, but `demo` runs on the VM, where `/srv`
did not exist. The test could never be true, so the "already exists →
just start it" branch was dead code and re-running fell through to `mpd
create` and failed with "Project already exists". It works now with no
edit to `demo` at all — worth knowing before rewriting around it.

**`demo` is the composite — there is no `mpd up`.** The question "should
`mpd start` create and configure when run from a project directory?" is
answered by this section rather than by a new verb: `start` stays
predictable (it starts what exists), and the one-command path from
nothing to a running site is `demo`, which already chains create →
configure → start. Its Moodle half is likewise already a tool —
`mdl-install`, the port of mdc's `site-install`. Nothing new is needed;
`demo` just needs a recipe where its flavour and tag are now.

**Open: does `demo` still belong in mpd?** As a mudev front-end it could
equally be `mudev demo`. mpd already provisions mudev at `--vm-setup` and
mounts it into every runtime, so the dependency is real either way; the
question is whose command it is. Worth settling before the rewrite rather
than after.

## Non-goals

- **Not** adding cwd inference to `start`/`stop`/`show`/`configure`
  beyond `create`, which needs it here. Same resolver, but each verb has
  its own questions — `delete` in particular, where inferring the project
  from the directory you are standing in deletes that directory out from
  under you. Worth doing, worth doing separately.
- **Not** specifying `MPD_RUNTIME` in `mpd.env` as the placement source of
  truth. This unblocks it; the create-flow inversion deserves its own
  design.

## Open question

Does `demo` stay an mpd command once it is a mudev front-end, or become
`mudev demo`? (Noted in §3; it is the one thing to settle before the
rewrite rather than after.)
