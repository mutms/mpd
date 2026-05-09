# Why mpd

**mpd is an AI-friendly Moodle plugin development environment.** Containers,
local DNS, automatic HTTPS — wired so an AI agent can SSH into a real
Moodle runtime, your git auth forwarded, and iterate against a fully
wired stack (Postgres/MariaDB/MySQL, Mailpit, automatic TLS for every
project URL — plus Behat + Selenium when a project opts in) without
you babysitting plumbing.

The shorter version: PHPStorm Gateway connects into the runtime; Claude
Code lands in the same place; both see the same Moodle install, the same
project files, the same `https://moodle51.mpd.test/`. Your laptop stays
clean — nothing dev-related lives on it. The runtime is the workspace.

## Where mpd came from

The public lineage:

- **[moodle-docker](https://github.com/moodlehq/moodle-docker)** — the
  official Docker-based Moodle dev environment. The reference everyone
  on macOS reaches for first.
- **[MDC](https://github.com/skodak/mdc)** — a macOS-only fork I ran for
  a while. It evolved to use [OrbStack](https://orbstack.dev/) instead of
  Docker Desktop because OrbStack was much faster and handled DNS + SSL
  automatically. That speed plus the `https://*.test` "it just works" UX
  changed how the day felt.
- **mpd** — the next step. Keeps the speed and the
  automatic-everything-on-`*.test`, adds firmer walls between dev work
  and the host, and is shaped explicitly for the AI-coding workflow that's
  redefined what dev environments need to do.

The reason for the second jump wasn't pace — MDC was faster than
anything else I'd tried, including production servers I still find
sluggish by comparison. The reason was scope and openness. I'm not
willing to install Homebrew, MacPorts, Node, PHP, or Apache on my
MacBook (personal stance, no exceptions), and I wanted every link in
the dev-environment trust chain to be open-source code I can read and
replace.

OrbStack is genuinely excellent — fast, the `*.test` UX is a delight,
automatic TLS that just works. But it's a closed-source commercial
product, and for a trust-boundary tool the bar I want is "I can read
the code that decides what gets trusted." mpd lives entirely in this
repo — Swift control plane plus shell tooling on top of Podman — with
a name-constrained local CA that can only sign for `*.mpd.test`. And
mpd ships a **Sandbox VM mode** as the recommended default —
a whole hypervisor between your dev work and your host, with
snapshot/revert as the safety net.

## Three things had to be true

**1. Containers always, never native installs.**

Nothing dev-related goes on the host. PHP, Composer, Behat, Selenium,
Postgres, Caddy (the HTTPS frontdoor) — all inside containers, all
isolated, all replaceable.
The host runs an IDE, a browser, a terminal; nothing else. mpd itself
follows the same rule: it's a Swift binary plus a small set of shell
scripts. Swift specifically because it's already on every Mac via the
Xcode command-line tools (no extra compiler to install) and because a
typed, memory-safe language is preferable to bash for the bits that
have to be reliable. `mpd --uninstall` removes mpd's state without
leaving you with a Mac that needs untangling.

**2. Speed, automatic DNS, automatic HTTPS.**

OrbStack-based MDC taught me that frictionless local HTTPS is *the*
dev-experience win for Moodle. Once `https://moodle51.mpd.test/` just
works — real cert, no warnings, no `--insecure`, no shell aliases to
remember — every other piece of the workflow snaps into place. You don't
go back. mpd preserves this: `mpd create <project> + configure + start`,
browser opens at the URL, it loads. If it doesn't, that's a bug in mpd,
not your problem.

The same applies per project: each project gets its own
`https://<project>.mpd.test/`, plus a Mailpit shortcut at
`https://mail.<project>.mpd.test/` (lands on the runtime's shared
mailpit, filtered to this project's mail), plus a Behat target at
`https://behat.<project>.mpd.test/` if the project asks for one. All of
it signed by the local CA, all of it routed automatically by dnsmasq +
the runtime's Caddy frontdoor. You don't configure any of it.

**3. SSH everywhere, IDE on the host.**

PHPStorm Gateway and VSCode Remote-SSH let your editor live on macOS
while the language server, Composer, Xdebug, phpunit, and the running
PHP-FPM all live inside the isolated runtime container. This isn't a
workaround — it's the *cleaner* design. There's no filesystem-mount
layer to paper over the network. There's no debate about where the code
"really" lives. The runtime is the workspace; the host is the thin
coordination layer.

That's why `mpd-machine` ships a fully headless VM. The dev never opens
a UTM window to look at it. They open PHPStorm, point Gateway at
`<vm-ip>`, and they're inside the runtime three seconds later. Same
shape for the AI agent: open a terminal on your laptop, SSH into the
runtime, then launch Claude Code (or Codex, Aider, etc.) inside that
SSH session. The agent now runs from inside the runtime — same files,
same tools, same Moodle install your IDE is editing.

## Where the AI runs

The AI agent's work involves executing arbitrary code, installing
packages, reading and writing project files, running tests, calling
system commands. That's exactly the surface mpd's containers and VM
boundary are designed to limit, so that's where the agent goes:

- **Inside the runtime container** — this is where the agent does
  the actual Moodle work: writing new plugins, fixing bugs in an
  existing project, generating phpunit tests, refactoring, running
  `mdl-cron` to verify a scheduled task, etc. Claude Code (or Codex /
  Cursor's AI-over-SSH / Aider) runs in the SSH session you open into
  the runtime, with `/srv/projects/<project>/` to work in and the
  installed `composer`/`phpunit`/`node` on PATH — same files, same
  tools as your IDE.
- **Inside the mpd-machine VM** — when the work is on **mpd itself**:
  editing the Swift sources under `~/Developer/mpd/`, rebuilding via
  `make install`, modifying asset scripts, debugging a runtime
  provisioning step. The VM is where mpd's source checkout and Swift
  toolchain live; that's where the agent goes when the bug is below
  the project layer.

This isn't a blanket "no AI on the host." Some host-side AI integrations
are well sandboxed already — Xcode's intelligence features run inside
Apple's own sandbox, often with stricter constraints than a generic AI
extension running inside an IDE on the host. The principle is about
where the AI does the *risky* work — the place where it can `rm -rf`,
install a malicious package, or break your build is the place that
should be inside mpd's boundary, not on your primary machine.

## Git auth without copying keys

mpd runs everything inside the runtime, including `git`. When you (or
the AI agent) commit and push, the runtime needs to authenticate
against GitHub / GitLab / your private remote.

The model is **SSH agent forwarding** (`ssh -A`), not "copy your
private key into the runtime":

```bash
ssh-add ~/.ssh/id_ed25519           # load the key into your laptop's
                                    # SSH agent (once per laptop session)
ssh -A user@php.runtime.mpd.test    # -A forwards the agent socket
                                    # into the runtime
cd /srv/projects/moodle51
git push origin main                # uses the forwarded agent;
                                    # GitHub sees your laptop's key
```

PHPStorm Gateway and VSCode Remote-SSH default to forwarding the agent,
so editor-side `git` operations work without extra setup. The AI agent
inside an SSH session you opened with `-A` uses the same forwarded
socket — Claude Code's `git push` from inside the runtime authenticates
against your GitHub account through your laptop's key.

The boundary: your private key **never leaves the laptop**. The runtime
can use the SSH agent (request signatures) only while your SSH session
is open, and only via the agent's signing API — there's no way to
extract the key. Close the SSH session, the auth goes away. Wipe or
compromise the runtime, and your key is unaffected.

This matters because mpd-machine is a sandbox you're meant to be able
to throw away. The whole "you can let the AI agent run wild" pitch
relies on the runtime *not* holding any secret that survives a wipe.

**One more practical guard.** Agent forwarding lets the AI push
commits *under your identity* — so the consequence-blocking moves to
GitHub's side, not the runtime's. The minimum recommended setting is
to **block force-pushes on protected branches** (`main`, release
branches) under *Settings → Branches → Branch protection rules*. That
way, every change the AI makes lands as an append-only commit that
you can audit; the agent can't quietly rewrite history. Stricter
shops should also require pull requests for `main` so each push is a
reviewable diff before it sticks.

## And one more thing changed

Until recently the SSHing into any server was the **nerd path**.
You had to know keys, agents, port forwarding, vim, journalctl, systemctl,
tmux. The traditional critique of SSH-based dev environments was always
"the learning curve excludes beginners." Fair, then.

Claude (and Codex, Cursor, Aider, the rest) has changed the cost of
that barrier. The SSH skills you used to need cold — keys, agent
forwarding, port forwarding, tmux survival, `journalctl` flags — are
now **learnable on demand**. The typical newcomer path proves it:

1. **Chat on your phone first.** Open Claude (or any AI chat) on a
   phone, ask it how to install SSH on your laptop, follow along.
2. **Set up your laptop.** Generate a key, run `ssh-add`, paste any
   error you hit back into the chat to get a fix.
3. **SSH into the VM.** The first connection always feels brittle;
   the chat coaches you past `Permission denied (publickey)`, agent
   forwarding, the host-key prompt.
4. **Get your own Claude Code inside.** Install it in the VM's
   terminal, or open PHPStorm Gateway and let it forward you in.
   From here your *own* AI agent — running inside the runtime —
   takes over the actual Moodle work.

And later — when something breaks or you forget — the loop is even
shorter. SSH complains about something in the terminal? Copy the
error, paste it into Claude (CLI, desktop, or web), get the fix in
roughly ten seconds. Agent forwarding stopped working? Runtime won't
accept your key? Forgot how to clear a stale `known_hosts` entry?
Paste the error, read the answer, move on. No Stack Overflow tab,
no manpage rabbit hole.

The SSH-into-runtime workflow is still real and you still drive it —
but the cost of learning each piece is "ask in English when you hit
one," not "read a sysadmin book first."

Which means the SSH-into-runtime design is no longer the nerd-tier
pattern. It's the *most accessible* way to give someone a real Moodle
stack to work in. Veterans drive it from muscle memory; newcomers
ride an AI tutor all the way from "I don't have SSH" to "I'm in the
runtime, my agent is editing Moodle code."

That's the inversion mpd is built around.

## What mpd feels like to work with

A morning session, on either mode:

```bash
mpd create moodle51 \
  --git-repo=https://github.com/moodle/moodle.git \
  --git-branch=MOODLE_501_STABLE
mpd configure moodle51
mpd start moodle51
```

That's a fully provisioned Moodle 5.1 instance: PHP runtime container,
Postgres container, Mailpit catching all
outbound mail, automatic TLS. Open `https://moodle51.mpd.test/` and the
admin install flow takes you the rest of the way.

Then PHPStorm Gateway → `php.runtime.mpd.test` (agent forwarded), open
the project at `/srv/projects/moodle51`, and you're editing in PHPStorm
with the language server, and phpunit running inside the runtime
container.

Or, working entirely inside PHPStorm:

1. Open the integrated terminal — Gateway already has it rooted in
   the runtime.
2. Install Claude Code in that session (one curl, ~30s).
3. Ask the agent: *"write a new local plugin called `localwhatever`
   hooked into the navigation block, with a phpunit test, then run
   all tests."* Or, on an existing project: *"find what's broken in
   the cron task and fix it."* The agent scaffolds, iterates, hits
   green; Mailpit catches any activation email at
   `https://mail.moodle51.mpd.test/`.

Mid-afternoon: `mpd --runtime-delete php`, then `mpd --runtime-create
php` again. Keep going. The runtime container is rebuildable; the data
volume keeps the projects and the DB.

Evening: `mpd --uninstall`. Mac is clean again. Nothing leftover except
`~/Developer/mpd/conf/` (the local CA, which you keep so tomorrow's
HTTPS still works without re-trusting). When you come back,
`mpd --setup` and you're 90 seconds from the same state.

## Three modes

The three modes differ in where you sit and where `mpd` runs.

**Sandbox VM** — full GNOME desktop inside the VM, and `mpd` runs
there too. You install Ubuntu 26.04 desktop in your hypervisor of
choice (UTM, Hyper-V, VirtualBox, virt-manager, VMware…), set the
hostname to `mpd-machine-sandbox`, take a snapshot, and run one bash
script inside the VM. GNOME terminal runs `mpd`; GNOME Firefox sees
`mpd.test`. The host is never touched. Lowest-friction entry,
strongest isolation for AI-driven workloads (the VM is the wall,
the snapshot is the safety net), recommended starting point if you
don't already know which mode to pick.

**mpd-machine** — automated headless Debian Trixie VM; you stay on
your host. The matched-host bootstrap (`setup.command` on macOS+UTM,
`setup.sh` on Ubuntu+KVM, `setup.cmd` on Windows+Hyper-V) creates
the VM with cloud-init, builds `mpd`, and configures the host's
route + DNS + CA trust so `https://mpd.test/` works in your laptop's
own browser. Your host browser visits `*.mpd.test` directly; your
host terminal SSH'es into the VM to use the `mpd` CLI (or PHPStorm
Gateway / VSCode Remote-SSH for IDE work). The VM has no GUI of its
own.

**mpd-desktop** — `mpd` is a native macOS binary you run directly in
your local Terminal — no SSH hop. macOS browser sees `*.mpd.test`
via a local WireGuard tunnel; Podman Desktop manages a Linux
container machine in the background. Pick this if you're already
invested in Podman Desktop or prefer not to drive a hypervisor
yourself.

**For Windows users specifically**, the sandbox or `mpd-machine`
Hyper-V path is the answer: either install Ubuntu 26.04 in any
Windows hypervisor and run `take-over-sandbox-vm.sh`, or
double-click `setup.cmd` for the host-integrated Hyper-V flow.
Windows itself stays untouched either way.

All three modes share the same `mpd.env` configuration model, the
same `https://<project>.mpd.test/` URLs, the same SSH-into-runtime
pattern. You can switch between them without re-learning.

## Where mpd is going

Near-term plans and parking-lot ideas live in
[`ROADMAP.md`](ROADMAP.md).

## Who mpd is for

**Today:** veteran Moodle developers who are already using AI coding
tools (Claude Code, Codex, Cursor, Aider) and want a Moodle dev
environment shaped around that workflow specifically. If you've used
moodle-docker or MDC and you've felt the friction of *the agent works in
the runtime but my IDE works on the host and somehow the filesystem is
a third place* — mpd resolves that. If you've felt the friction of *I
can't let the agent do anything destructive because it would touch my
host* — mpd-machine resolves that.

**Tomorrow:** Moodle-curious people who are not (yet) Moodle developers.
A friend, a colleague, a junior, a domain expert who wants to try
building a local plugin. The combination of *real Moodle running locally
+ Cloudflare-published preview URL + AI agent doing the typing* is a
soft landing for someone who's never opened a PHP file. That direction
is what the `publish` roadmap item enables.

## License and acknowledgments

GPL-3.0-or-later. © 2026 Petr Skoda.

mpd is my first fully AI-driven project. It was built with
[Claude Code](https://claude.ai/code) (Anthropic) and
[Codex](https://openai.com/codex/) (OpenAI). I'd like other Moodle
developers to feel what working this way is like — that's why mpd is
open source, and that's why it ships with the docs you're reading
instead of a "TODO: write docs" placeholder.

Moodle is a registered trademark of [Moodle Pty Ltd](https://moodle.com).
