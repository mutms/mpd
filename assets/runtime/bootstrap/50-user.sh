#!/bin/bash
# 50-user.sh — the runtime's one root-context script (the bootstrap
# exception in AGENTS.md §"Mandatory privilege rule"): the dev user does
# not exist yet, so nothing else could create it. Run by mpd once, at
# runtime create, as root via `podman exec`. Safe to re-run.
#
#   50-user.sh <container> <user> <uid> <zone>
set -euo pipefail

CONTAINER_NAME="$1"
EXTUSER="$2"
EXTUID="$3"
MPD_ZONE="$4"   # this VM's zone, e.g. 222.mpd.test — /srv/meta may not exist yet

# Lift systemd's per-service task cap: DefaultTasksMax is 15% of the pids
# limit and every service inherits it — ssh.service holds the whole IDE
# backend + agent + git, which alone exceeds it and dies with EAGAIN.
mkdir -p /etc/systemd/system.conf.d
printf '[Manager]\nDefaultTasksMax=infinity\n' > /etc/systemd/system.conf.d/mpd-tasksmax.conf
systemctl daemon-reexec

# sshd: keys only, no root.
printf '%s\n' 'PermitRootLogin no' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' \
    > /etc/ssh/sshd_config.d/10-mpd.conf
systemctl enable ssh
systemctl restart ssh

# Identity.
grep -q " ${CONTAINER_NAME}.runtime.${MPD_ZONE}$" /etc/hosts \
    || echo "127.0.0.1  ${CONTAINER_NAME}.runtime.${MPD_ZONE}" >> /etc/hosts
mkdir -p /etc/mpd
echo "${CONTAINER_NAME}" > /etc/mpd/runtime

# Dev user with the VM's uid, so files on /srv have one owner on both sides.
if ! id "${EXTUSER}" &>/dev/null; then
    useradd -m -u "${EXTUID}" -s /bin/bash "${EXTUSER}"
fi
echo "${EXTUSER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${EXTUSER}"
chmod 440 "/etc/sudoers.d/${EXTUSER}"

USER_HOME="/home/${EXTUSER}"

# Home from skel: shipped defaults, then the VM's /var/lib/mpd/skel
# overrides (mounted read-only). cp -aT merges contents, dotfiles included.
cp -aT /opt/mpd/assets/runtime/skel "${USER_HOME}"
if [ -d /var/lib/mpd/skel ]; then
    cp -aT /var/lib/mpd/skel "${USER_HOME}"
fi
mkdir -p "${USER_HOME}/.local/bin"
chown -R "${EXTUSER}:${EXTUSER}" "${USER_HOME}"
chmod 700 "${USER_HOME}/.ssh" 2>/dev/null || true

# Data volume layout.
mkdir -p /srv/projects /srv/data /srv/dbs /srv/extra
chown "${EXTUSER}:${EXTUSER}" /srv/projects /srv/data /srv/extra
chown root:root /srv/dbs
chmod 0755 /srv/dbs
