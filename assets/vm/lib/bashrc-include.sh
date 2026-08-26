# bashrc-include.sh — the mpd part of the VM dev user's interactive shell.
#
# The VM-side twin of assets/runtime/lib/bashrc-include.sh. It is NOT copied
# into the user's home: bootstrap/30-mpd-build.sh injects a single line near the
# top of the dev user's ~/.bashrc that sources this file, and everything mpd
# needs in that shell lives here. So mpd edits ~/.bashrc exactly once, at
# adoption, with one line the user is free to keep or move; every later change
# happens in this file, which is read live from /opt/mpd (git-pulled by
# `mpd --vm-upgrade`) and so reaches the next shell with no ~/.bashrc edit.
#
# Unlike the runtime, the VM's dev account already exists at adoption, so there
# is no fresh home to seed a stub into — hence the one injected source line.
#
# Sourced near the TOP of ~/.bashrc, before Debian's `*) return;;`
# non-interactive guard, on purpose: bash sources ~/.bashrc for SSH command
# execution when stdin is a socket (`ssh user@vm cmd`), and mpd-virt drives the
# VM over exactly such shells — they must have /opt/mpd/bin on PATH. Anything
# here therefore runs for non-interactive shells too; guard interactive-only
# work on ${PS1-} and keep it cheap.

# --- PATH: mpd + VM tools + user-installed CLIs ----------------------------
# /opt/mpd/bin        the mpd binary
# /opt/mpd/assets/vm/bin  the VM tools (container, gnome-*, rdp-*, claude-install)
# ~/.local/bin        personal installs (claude-install drops binaries here);
#                     Debian only adds it via ~/.profile at login, so prepend
#                     unconditionally to reach it mid-session too. bootstrap
#                     pre-creates the dir.
PATH="$HOME/.local/bin:/opt/mpd/bin:/opt/mpd/assets/vm/bin:$PATH"

# --- the developer's own environment ---------------------------------------
# vm.env is the VM-side twin of the runtime's runtime.env: general-purpose
# variables the developer wants in every VM shell and execution. mpd-virt pushes
# ~/.mpd-virt/vm.env to /var/lib/mpd/env/vm.env; the block is inert until then.
# Plain-sourced, NOT whitelist-parsed like a project mpd.env — it is the
# developer's own trusted file, never from git, so it may export non-MPD_
# variables too.
if [ -f /var/lib/mpd/env/vm.env ]; then
    set -a
    # shellcheck source=/dev/null
    . /var/lib/mpd/env/vm.env
    set +a
fi

# --- Prompt: show the -vm alias, and a key when the agent is forwarded ------
# The host-side alias for this machine is `mpd-<NNN>-vm` (the bare `mpd-<NNN>`
# reaches the runtime container instead), while the VM's own hostname is
# `mpd-<NNN>` — so `\h` in Debian's default PS1 would echo a name that means
# the other machine. Rewrite just the `\h` token, leaving Debian's colours and
# chroot prefix intact. Cosmetic only: the hostname is never changed, so
# `hostname`, DNS, mpd's identity and cloud-init all still see `mpd-<NNN>`.
#
# The 🔑 marks a session carrying a forwarded SSH agent (`ssh -A`), so whether
# `git push` can reach a workstation key is visible in the prompt rather than
# recalled from the ssh line. SSH_AUTH_SOCK is set only when forwarding was
# asked for; SSH_CONNECTION pins it to an SSH session (a desktop agent in the
# VM's own GNOME session is not agent forwarding).
#
# Applied through PROMPT_COMMAND, not inline: this file is sourced at the top of
# ~/.bashrc, before Debian assigns PS1, so an inline rewrite would be lost. The
# hook runs before each prompt — after PS1 is set — and both tweaks are
# idempotent, so re-running is a no-op.
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
