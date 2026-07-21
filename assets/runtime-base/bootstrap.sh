#!/bin/bash
# bootstrap.sh — turns a fresh Debian Trixie container into a runtime base.
#
# THE ONE ROOT-CONTEXT SCRIPT. The single bootstrap exception named in
# AGENTS.md §"Mandatory privilege rule": runs as root because the dev
# user does not yet exist when it starts. Called only by Mpd.Runtime
# during runtime creation; nothing else may invoke it.
#
# After this returns, the container is a "runtime base":
#   - common dev tools + openssh-server installed
#   - sshd configured (PermitRootLogin no, pubkey auth)
#   - dev user created with matching UID and passwordless sudo
#   - /etc/mpd/runtime identity, /etc/hosts self-record (in this VM's zone)
#   - /home/<user>/ seeded from skel (defaults + optional VM-host overrides)
#   - /srv/{projects,data,dbs,extra} laid out with correct ownership
#
# Runtime-specific layers (PHP, Node, …) are added on top by
# assets/runtimes/<rt>/build.sh running as the dev user.
set -euo pipefail

CONTAINER_NAME="$1"
EXTUSER="$2"
EXTUID="$3"
# This VM's DNS zone (e.g. 222.mpd.test) — passed in because the container
# has no access to /var/lib/mpd/conf/platform.env and /srv/meta/vm.json is
# not guaranteed to exist yet this early in provisioning.
MPD_ZONE="$4"

export DEBIAN_FRONTEND=noninteractive

# --- Common developer tools ---
# The last line is extra tooling for AI agents: shellcheck/shfmt for the
# shell mpd ships, ripgrep for searching large project trees. Not `gh` —
# it is useless until `gh auth login` stores a token in the container,
# and git auth here is the developer's forwarded SSH agent.
apt-get update -qq
apt-get install -y --no-install-recommends \
    bash-completion bc bzip2 curl dnsutils file findutils git gzip htop \
    iproute2 iputils-ping jq less lftp locales locales-all lsof man-db mc \
    nano net-tools netcat-openbsd openssh-client openssh-server patch procps \
    psmisc rsync screen socat strace sudo tar telnet time tmux tree unzip \
    vim wget whois xz-utils zip \
    shellcheck shfmt ripgrep

# --- OpenSSH (root login disabled; user login via Mac SSH key) ---
mkdir -p /root/.ssh
chmod 700 /root/.ssh
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
systemctl enable ssh
systemctl restart ssh || systemctl start ssh

# --- Internal hostname ---
echo "127.0.0.1  ${CONTAINER_NAME}.runtime.${MPD_ZONE}" >> /etc/hosts

# --- Runtime identity (read by project scripts) ---
mkdir -p /etc/mpd
echo "${CONTAINER_NAME}" > /etc/mpd/runtime

# --- Dev user (matching UID for correct volume file ownership) ---
if ! id "${EXTUSER}" &>/dev/null; then
    useradd -m -u "${EXTUID}" -s /bin/bash "${EXTUSER}"
fi

# Passwordless sudo for the dev user.
echo "${EXTUSER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${EXTUSER}"
chmod 440 "/etc/sudoers.d/${EXTUSER}"

USER_HOME="/home/${EXTUSER}"

# --- Skel: seed /home/<user>/ from shipped defaults + VM-host overrides ---
# Two layers, last wins:
#   1. /opt/mpd/assets/runtime-base/skel/   (shipped defaults — known_hosts,
#                                            .bashrc with PATH + cd + nvm)
#   2. /var/lib/mpd/skel/                   (VM-host overrides — optional;
#                                            user-managed, copied if present)
#
# /var/lib/mpd/ on the VM is bind-mounted at the same path inside this
# container (well, only /var/lib/mpd/env/ is — the rest isn't visible
# here). The /var/lib/mpd/skel/ tree is mounted RO via podman.SkelMountRO
# (see go/internal/runtime/runtime.go) so this script can read it.
#
# cp -aT copies CONTENTS of src into dst (the trailing T is important —
# without it cp would create /home/<user>/skel/ instead of merging into
# /home/<user>/). -a preserves modes; dotfiles included.
cp -aT /opt/mpd/assets/runtime-base/skel "${USER_HOME}"
if [ -d /var/lib/mpd/skel ]; then
    cp -aT /var/lib/mpd/skel "${USER_HOME}"
fi

# Pre-create ~/.local/bin so user-installed CLIs (claude-install drops
# binaries there) land in a dir that exists and is on PATH (the skel
# .bashrc prepends it unconditionally) from the very first shell.
mkdir -p "${USER_HOME}/.local/bin"

# Take ownership of everything in the dev user's home — useradd -m already
# created the dir with the right owner, but cp -a inherited root for the
# copied entries.
chown -R "${EXTUSER}:${EXTUSER}" "${USER_HOME}"

# .ssh needs strict mode regardless of what skel shipped.
chmod 700 "${USER_HOME}/.ssh" 2>/dev/null || true

# --- Shared volume directories ---
mkdir -p /srv/projects /srv/data /srv/dbs /srv/extra
chown "${EXTUSER}:${EXTUSER}" /srv/projects /srv/data /srv/extra
chown root:root /srv/dbs
chmod 0755 /srv/dbs

