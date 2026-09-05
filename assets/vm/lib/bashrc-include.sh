# bashrc-include.sh — the mpd part of the dev user's shell. Sourced by
# one managed line bootstrap/30-mpd-build.sh puts at the TOP of ~/.bashrc,
# before Debian's non-interactive return guard, on purpose: bash sources
# ~/.bashrc for `ssh user@vm cmd`, and those shells need /opt/mpd/bin on
# PATH. Everything here runs for non-interactive shells too — guard
# interactive-only work on ${PS1-} and keep it cheap.
# Read live from /opt/mpd, so edits reach the next shell with no
# ~/.bashrc change.

# vm.env: the developer's own variables for every shell (see AGENTS.md
# "Fixed in-VM paths"). Plain-sourced, not whitelist-parsed like a
# project mpd.env: it is the developer's trusted file, never from git.
if [ -f /var/lib/mpd/env/vm.env ]; then
    set -a
    # shellcheck source=/dev/null
    . /var/lib/mpd/env/vm.env
    set +a
fi

# mpd tool dirs, read live from /opt/mpd. Precedence is vm < project type
# (docs/architecture.md §7); each entry prepends, so the last one added
# wins. Root has none of this on PATH by design.
_mpd_assets=/opt/mpd/assets

[ -d "${_mpd_assets}/vm/bin" ] && PATH="${_mpd_assets}/vm/bin:$PATH"
for _d in "${_mpd_assets}/vm"/project_types/*/bin; do
    [ -d "$_d" ] && PATH="${_d}:$PATH"
done

# A project type may ship a shellrc.sh exporting env its upstream tooling
# reads on its own. Keep them to exports: this also runs on every
# non-interactive `ssh <vm> <cmd>`.
for _d in "${_mpd_assets}/vm"/project_types/*/shellrc.sh; do
    [ -f "$_d" ] && . "$_d"
done
unset _d _mpd_assets

# mudev is built separately; a VM without it simply has no directory here.
[ -x /opt/mudev/bin/mudev ] && PATH="/opt/mudev/bin:$PATH"

# Absent until `make install` has run.
[ -x /opt/mpd/bin/mpd ] && PATH="/opt/mpd/bin:$PATH"

# User-installed CLIs (claude-install drops binaries here). Unguarded on
# purpose: a CLI installed mid-session is found by the shell that
# installed it. Debian adds it only via ~/.profile at login.
PATH="$HOME/.local/bin:$PATH"

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# No cd here, on purpose: a login shell that sets its own directory
# overrides PhpStorm remote sessions.

# The key marker flags a forwarded SSH agent (`ssh -A`); SSH_CONNECTION
# excludes a desktop agent in the VM's own GNOME session.
# Applied through PROMPT_COMMAND, not inline: this file runs before
# Debian assigns PS1, so an inline rewrite would be lost. Idempotent.
if [ -n "${PS1-}" ]; then
    _mpd_prompt() {
        if [ -n "${SSH_AUTH_SOCK-}" ] && [ -n "${SSH_CONNECTION-}" ]; then
            # Match the marker ANYWHERE, not just as a prefix: terminals with
            # their own prompt integration (JetBrains JediTerm) prepend escape
            # sequences to PS1 each prompt, so a prefix-only check misses the
            # existing 🔑 and stacks a new one every time (🔑 🔑 🔑 …).
            case "$PS1" in
                *'🔑 '*) ;;
                *) PS1="🔑 $PS1" ;;
            esac
        fi
    }
    case "${PROMPT_COMMAND-}" in
        *_mpd_prompt*) ;;
        *) PROMPT_COMMAND="_mpd_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
    esac
fi
