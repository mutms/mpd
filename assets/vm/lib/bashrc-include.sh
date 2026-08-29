# bashrc-include.sh — the mpd part of the VM dev user's shell. Sourced by
# one managed line bootstrap/30-mpd-build.sh puts at the TOP of ~/.bashrc,
# before Debian's non-interactive return guard, on purpose: bash sources
# ~/.bashrc for `ssh user@vm cmd`, and those shells need /opt/mpd/bin on
# PATH. Everything here runs for non-interactive shells too — guard
# interactive-only work on ${PS1-} and keep it cheap.
# Read live from /opt/mpd, so edits reach the next shell with no
# ~/.bashrc change.

# ~/.local/bin comes first: Debian adds it only via ~/.profile at login,
# so prepend here to reach mid-session installs (claude-install) too.
PATH="$HOME/.local/bin:/opt/mpd/bin:/opt/mpd/assets/vm/bin:$PATH"

# vm.env: the developer's own variables for every VM shell (see AGENTS.md
# "Fixed in-VM paths"). Plain-sourced, not whitelist-parsed like a
# project mpd.env: it is the developer's trusted file, never from git.
if [ -f /var/lib/mpd/env/vm.env ]; then
    set -a
    # shellcheck source=/dev/null
    . /var/lib/mpd/env/vm.env
    set +a
fi

# Prompt: rewrite the `\h` token to `\h-vm` — the host-side alias for
# this machine is mpd-<NNN>-vm, while bare mpd-<NNN> reaches the runtime
# container. Cosmetic only; the hostname itself never changes.
# The key marker flags a forwarded SSH agent (`ssh -A`); SSH_CONNECTION
# excludes a desktop agent in the VM's own GNOME session.
# Applied through PROMPT_COMMAND, not inline: this file runs before
# Debian assigns PS1, so an inline rewrite would be lost. Both tweaks are
# idempotent.
if [ -n "${PS1-}" ]; then
    _mpd_vm_prompt() {
        case "$PS1" in
            *'\h-vm'*) ;;
            *'\h'*) PS1="${PS1//\\h/\\h-vm}" ;;
        esac
        if [ -n "${SSH_AUTH_SOCK-}" ] && [ -n "${SSH_CONNECTION-}" ]; then
            case "$PS1" in
                '🔑 '*) ;;
                *) PS1="🔑 $PS1" ;;
            esac
        fi
    }
    case "${PROMPT_COMMAND-}" in
        *_mpd_vm_prompt*) ;;
        *) PROMPT_COMMAND="_mpd_vm_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
    esac
fi
