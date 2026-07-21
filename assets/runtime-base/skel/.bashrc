# mpd runtime — default .bashrc.
#
# Shipped via skel into /home/<user>/.bashrc on runtime create. Edit at
# will; changes persist for this runtime's lifetime. A runtime recreate
# (mpd --runtime-delete + recreate) restores this template. To override
# the default for every new runtime, drop a replacement at
# /var/lib/mpd/skel/.bashrc on the VM host.
#
# Bash sources this file for both interactive shells AND for SSH command
# execution when stdin is connected to a socket (sshd-shaped). So
# `ssh user@runtime cmd` reaches the same PATH as `ssh user@runtime`
# followed by typing cmd.

# Source the distro's default per-user bashrc that this file displaced
# (useradd -m seeds it from /etc/skel, then the mpd skel copy overwrites
# it). Debian keeps the colored prompt, dircolors/ls aliases, and history
# defaults there — sourcing it keeps us tracking upstream instead of
# duplicating it. Its own interactivity guard makes it a no-op for
# non-interactive (sshd command-execution) shells; the mpd-specific lines
# below still apply either way.
[ -f /etc/skel/.bashrc ] && . /etc/skel/.bashrc

# --- mpd tool dirs on PATH -------------------------------------------------
# Every dir under /srv/tools/ (base + the active runtime + per-project-type
# tool dirs) goes on PATH. The glob is self-extending — runtimes/types that
# create new tools dirs are picked up without editing this file.
#
# Precedence is base < runtime < project type (ARCHITECTURE.md §7), so a
# type tool shadows a runtime tool of the same name. Each entry prepends,
# so the *last* one added wins — hence base first, runtime second, types
# last. Do not collapse this back into a single `/srv/tools/*/` glob:
# alphabetical order is not the precedence order (`php` sorts after
# `moodle`, which would rank the runtime above the project type).
#
# The dev user is the only login identity inside a runtime. Root has none
# of this on PATH by design: `sudo composer install` returns "command not
# found" so the operation is forced back to the dev user, which is the
# correct privilege model for mpd tools (see AGENTS.md "Mandatory privilege
# rule").
_mpd_rt="$(cat /etc/mpd/runtime 2>/dev/null || true)"
for _d in /srv/tools/_base "/srv/tools/${_mpd_rt}"; do
    [ -n "${_d#/srv/tools/}" ] && [ -d "$_d" ] && PATH="${_d}:$PATH"
done
# Whatever is left is a project-type tool dir — highest precedence.
for _d in /srv/tools/*/; do
    _d="${_d%/}"
    case "$_d" in
        /srv/tools/_base|"/srv/tools/${_mpd_rt}") continue ;;
    esac
    PATH="${_d}:$PATH"
done
unset _d _mpd_rt

# --- User-installed CLIs ---------------------------------------------------
# Claude Code, gh, and other tools that ship via personal `~/.local/bin`
# installs (claude-install drops binaries here). Unguarded on purpose:
# bootstrap.sh pre-creates the dir, and an unconditional prepend means a
# CLI installed mid-session is found by the very shell that installed it.
PATH="$HOME/.local/bin:$PATH"

# --- nvm (Node Version Manager) -------------------------------------------
# Sourced only when nvm is actually installed; node-install runs in the
# runtime's build phase and lands here. The lazy export keeps shell start
# fast when nvm isn't relevant for the runtime.
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# --- Sane default working directory for SSH sessions ----------------------
# Mpd runtimes are project-shaped: SSH-ing in lands the user in /srv/projects
# so `cd <project>` is the next step instead of `cd /srv/projects && cd <p>`.
cd /srv/projects 2>/dev/null || true
