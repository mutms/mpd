# mpd runtime — default .bashrc.
#
# Shipped via skel into /home/<user>/.bashrc on runtime create. Edit at
# will; changes persist for this runtime's lifetime. A rebuild
# (mpd --runtime-rebuild) restores this template. To override
# the default for a rebuilt runtime, drop a replacement at
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
# Tools are read straight out of the assets tree, which is bind-mounted at
# /opt/mpd in every container at the same path it has on the VM. There is
# no copy and no symlink farm: editing a tool on the VM changes it here
# immediately.
#
# Precedence is base < runtime < project type (ARCHITECTURE.md §7), so a
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

[ -d "${_mpd_assets}/runtime-base/tools" ] && PATH="${_mpd_assets}/runtime-base/tools:$PATH"
[ -d "${_mpd_assets}/runtime/tools" ] && PATH="${_mpd_assets}/runtime/tools:$PATH"
for _d in "${_mpd_assets}/runtime"/project_types/*/tools; do
    [ -d "$_d" ] && PATH="${_d}:$PATH"
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
# `mpd create`, `mpd start` and friends work from here without a second
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
