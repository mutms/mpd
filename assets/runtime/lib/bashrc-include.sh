# bashrc-include.sh — the mpd part of every runtime's interactive shell.
#
# This is NOT copied into the runtime. It lives in the assets tree, which is
# bind-mounted read-only at /opt/mpd on every runtime, and is sourced live by
# the skel ~/.bashrc:
#
#     [ -f /opt/mpd/assets/runtime/lib/bashrc-include.sh ] \
#         && . /opt/mpd/assets/runtime/lib/bashrc-include.sh
#
# That indirection is the whole point. The skel ~/.bashrc is *copied* into a
# runtime's home at create time and then frozen for that runtime's life — so
# every edit to it reaches only future runtimes, and a mistake bakes itself
# into homes already out there. This file is read fresh on each shell start
# from the shared mount, so editing it (then `mpd --vm-upgrade`, which git-pulls
# the assets tree) takes effect in the very next shell of every existing
# runtime, with no rebuild. Keep the skel ~/.bashrc a stub; put changes here.
#
# Bash sources ~/.bashrc — and therefore this — for interactive shells AND for
# SSH command execution when stdin is a socket (sshd-shaped). So
# `ssh user@runtime cmd` reaches the same PATH as an interactive login. Guard
# anything prompt-only on ${PS1-}, and keep non-interactive work cheap: the
# lines here run on every remote `ssh runtime <cmd>`.

# --- the developer's own environment ---------------------------------------
# runtime.env is the runtime-side twin of the VM's vm.env: general-purpose
# variables the developer wants in every runtime shell and execution (a Moodle
# admin password mdl-install reads, an API token, whatever). mpd-virt pushes
# ~/.mpd-virt/runtime.env to /var/lib/mpd/env/runtime.env, bind-mounted RO
# here; the block is inert until then. Plain-sourced, NOT whitelist-parsed
# like a project mpd.env — it is the developer's own trusted file, never from
# git, so it may export non-MPD_ variables too. This is ambient shell
# environment, not part of mpd's mpd.env config layering (source-mpd-env.sh).
if [ -f /var/lib/mpd/env/runtime.env ]; then
    set -a
    # shellcheck source=/dev/null
    . /var/lib/mpd/env/runtime.env
    set +a
fi

# --- mpd tool dirs on PATH -------------------------------------------------
# Tools are read straight out of the assets tree, which is bind-mounted at
# /opt/mpd in every container at the same path it has on the VM. There is
# no copy and no symlink farm: editing a tool on the VM changes it here
# immediately.
#
# Precedence is base < runtime < project type (architecture.md §7), so a
# type tool shadows a runtime tool of the same name. Each entry prepends,
# so the *last* one added wins — hence base first, runtime second, types
# last.
#
# The dev user is the only login identity inside a runtime. Root has none
# of this on PATH by design: `sudo composer install` returns "command not
# found" so the operation is forced back to the dev user, which is the
# correct privilege model for mpd tools (see AGENTS.md "Mandatory privilege
# rule").
_mpd_assets=/opt/mpd/assets

[ -d "${_mpd_assets}/runtime/bin" ] && PATH="${_mpd_assets}/runtime/bin:$PATH"
for _d in "${_mpd_assets}/runtime"/project_types/*/bin; do
    [ -d "$_d" ] && PATH="${_d}:$PATH"
done

# --- project-type shell hooks ----------------------------------------------
# A type may ship a shellrc.sh to put something in the environment that its
# upstream tooling reads on its own — the case that earns this is a tool mpd
# does not wrap, where the alternative would be asking the developer to pass
# a flag the tool's own docs never mention.
#
# Sourced live from the assets tree like the tool dirs above, so editing a
# shellrc.sh on the VM takes effect in the next shell with no rebuild. Keep
# them to exports: this runs on every non-interactive `ssh runtime <cmd>`
# too, so anything slow here is paid on every remote command.
for _d in "${_mpd_assets}/runtime"/project_types/*/shellrc.sh; do
    [ -f "$_d" ] && . "$_d"
done
unset _d _mpd_assets

# mudev is built once on the VM (it needs Go and make) and bind-mounted
# read-only into every runtime at the same path, so the binary is shared
# rather than rebuilt per runtime. Guarded: a VM whose mudev has not been
# provisioned simply has no mount here.
[ -x /opt/mudev/bin/mudev ] && PATH="/opt/mudev/bin:$PATH"

# --- mpd itself ------------------------------------------------------------
# The same binary the VM runs, reached through the read-only /opt/mpd mount.
# It detects that it is inside a runtime (via /etc/mpd/runtime) and forwards
# project commands to the VM over this runtime's control socket, so
# `mpd init`, `mpd start` and friends work from here without a second
# terminal. Guarded because /opt/mpd/bin/mpd only exists once the VM has
# been built with `make install`.
[ -x /opt/mpd/bin/mpd ] && PATH="/opt/mpd/bin:$PATH"

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

# --- No default working directory ------------------------------------------
# This file deliberately does NOT cd anywhere. It used to land SSH sessions
# in /srv/projects as a convenience, which turned out to fight every tool
# that sets its own directory: PhpStorm's remote sessions, and `podman exec
# -w`, which the shell then silently overrode. A login shell that moves you
# is a shell that lies to its caller.

# --- Prompt: match the alias you typed -------------------------------------
# The host-side alias for this container is `mpd-<NNN>` (mpd-virt writes it),
# but the container's hostname is `mpd-<NNN>-runtime`, so `\h` in Debian's
# default PS1 would echo something you did not type. Rewrite just the `\h`
# token in the PS1 Debian already built, so its colours and the chroot
# prefix survive untouched. Hostnames themselves are never changed - mpd's
# identity, DNS and `podman ps` all still see the real name.
if [ -n "${PS1-}" ]; then
    _mpd_h=${HOSTNAME%%.*}
    _mpd_h=${_mpd_h%-runtime}
    case "$PS1" in
        *'\h'*) PS1="${PS1//\\h/$_mpd_h}" ;;
    esac
    unset _mpd_h
fi

# A key on the prompt when this session carries a forwarded SSH agent, so
# whether `git push` can reach a workstation key is a visible property of
# the shell rather than something to recall from the ssh command line.
# `ssh -A mpd-<NNN>` forwards to here, through the VM.
#
# No convention exists for showing it; the standard part is the detection.
# sshd exports SSH_AUTH_SOCK only when the client asked for forwarding —
# it is what ssh and git themselves look at. SSH_CONNECTION pins this to
# an SSH session, so `podman exec` shells never light the key.
#
# Evaluated once at shell start, like the socket. If the forwarded agent
# goes away mid-session the key stays lit; `ssh-add -l` is the live answer.
if [ -n "${PS1-}" ] && [ -n "${SSH_AUTH_SOCK-}" ] && [ -n "${SSH_CONNECTION-}" ]; then
    case "$PS1" in
        '🔑 '*) ;;
        *) PS1="🔑 $PS1" ;;
    esac
fi
