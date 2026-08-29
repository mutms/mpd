# bashrc-include.sh — the mpd part of every runtime's interactive shell.
#
# Sourced live from the read-only /opt/mpd bind mount by the runtime's
# ~/.bashrc. That ~/.bashrc copy is frozen at runtime create; keep it a
# stub and put changes here, where every existing runtime picks them up
# on the next shell. See docs/architecture.md §7.
#
# Bash sources ~/.bashrc for interactive shells AND for SSH command
# execution, so this runs on every `ssh runtime <cmd>`. Guard prompt-only
# work on ${PS1-} and keep everything else cheap.

# runtime.env is the developer's own ambient environment, pushed by
# mpd-virt to /var/lib/mpd/env/. Trusted (never from git), so it is
# plain-sourced, unlike the whitelist-parsed mpd.env layers
# (source-mpd-env.sh).
if [ -f /var/lib/mpd/env/runtime.env ]; then
    set -a
    # shellcheck source=/dev/null
    . /var/lib/mpd/env/runtime.env
    set +a
fi

# mpd tool dirs, read live from the /opt/mpd mount. Precedence is base <
# runtime < project type (docs/architecture.md §7); each entry prepends,
# so the last one added wins. Root has none of this on PATH by design.
_mpd_assets=/opt/mpd/assets

[ -d "${_mpd_assets}/runtime/bin" ] && PATH="${_mpd_assets}/runtime/bin:$PATH"
for _d in "${_mpd_assets}/runtime"/project_types/*/bin; do
    [ -d "$_d" ] && PATH="${_d}:$PATH"
done

# A project type may ship a shellrc.sh exporting env its upstream tooling
# reads on its own. Keep them to exports: this also runs on every
# non-interactive `ssh runtime <cmd>`.
for _d in "${_mpd_assets}/runtime"/project_types/*/shellrc.sh; do
    [ -f "$_d" ] && . "$_d"
done
unset _d _mpd_assets

# mudev is built once on the VM and bind-mounted read-only; a VM without
# mudev simply has no mount here.
[ -x /opt/mudev/bin/mudev ] && PATH="/opt/mudev/bin:$PATH"

# The VM's own mpd binary. Inside a runtime it forwards project commands
# to the VM over the control socket. Absent until `make install` has run.
[ -x /opt/mpd/bin/mpd ] && PATH="/opt/mpd/bin:$PATH"

# User-installed CLIs (claude-install drops binaries here). Unguarded on
# purpose: a CLI installed mid-session is found by the shell that
# installed it.
PATH="$HOME/.local/bin:$PATH"

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# No cd here, on purpose: a login shell that sets its own directory
# overrides PhpStorm remote sessions and `podman exec -w`.

# The host-side alias is `mpd-<NNN>` but the hostname is
# `mpd-<NNN>-runtime`, so `\h` would echo a name you did not type.
# Rewrite only the `\h` token; colours and hostnames stay untouched.
if [ -n "${PS1-}" ]; then
    _mpd_h=${HOSTNAME%%.*}
    _mpd_h=${_mpd_h%-runtime}
    case "$PS1" in
        *'\h'*) PS1="${PS1//\\h/$_mpd_h}" ;;
    esac
    unset _mpd_h
fi

# Show a key on the prompt when the session carries a forwarded SSH agent
# (`ssh -A`). sshd exports SSH_AUTH_SOCK only when forwarding was asked
# for; SSH_CONNECTION keeps `podman exec` shells unlit. Evaluated once at
# shell start; `ssh-add -l` is the live answer.
if [ -n "${PS1-}" ] && [ -n "${SSH_AUTH_SOCK-}" ] && [ -n "${SSH_CONNECTION-}" ]; then
    case "$PS1" in
        '🔑 '*) ;;
        *) PS1="🔑 $PS1" ;;
    esac
fi
