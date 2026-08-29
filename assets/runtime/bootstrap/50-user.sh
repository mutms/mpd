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

# sshd host keys: this runtime's own, kept across rebuilds.
#
# A host key is a secret, so it is made here and never shipped: the image
# carries none (see the Containerfile), each runtime generates its own on
# first create, and the keys are kept on the VM at the path below —
# mounted into this container and no other — so `mpd --runtime-rebuild`
# comes back as the same host instead of tripping a host-key warning on
# the developer's workstation.
#
# Both branches clear /etc/ssh first, so a key left behind by a partial
# run cannot outlive it.
SSH_KEEP=/var/lib/mpd/state/runtime-ssh
if compgen -G "${SSH_KEEP}/ssh_host_*_key" > /dev/null; then
    rm -f /etc/ssh/ssh_host_*
    cp -a "${SSH_KEEP}"/ssh_host_* /etc/ssh/
else
    rm -f /etc/ssh/ssh_host_*
    ssh-keygen -A
    mkdir -p "${SSH_KEEP}"
    cp -a /etc/ssh/ssh_host_* "${SSH_KEEP}"/
fi
chmod 600 /etc/ssh/ssh_host_*_key
chmod 644 /etc/ssh/ssh_host_*_key.pub

# sshd: keys only, no root.
printf '%s\n' 'PermitRootLogin no' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' \
    > /etc/ssh/sshd_config.d/10-mpd.conf
systemctl enable ssh
# Restart, not reload: sshd is already up with the image's keys by the time
# this runs, and it reads host keys at start.
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

# Home files. The account is fresh here, so both flavours are just copied in:
# default/ (the dev's to edit after) and forced/ (mpd's, re-applied on every
# --vm-setup by 70-configure-runtime.sh). Then the VM-host /var/lib/mpd/home
# override. cp -aT merges contents, dotfiles included.
for d in default forced; do
    [ -d "/opt/mpd/assets/runtime/home/${d}" ] && \
        cp -aT "/opt/mpd/assets/runtime/home/${d}" "${USER_HOME}"
done
if [ -d /var/lib/mpd/home ]; then
    cp -aT /var/lib/mpd/home "${USER_HOME}"
fi
mkdir -p "${USER_HOME}/.local/bin"
chown -R "${EXTUSER}:${EXTUSER}" "${USER_HOME}"
chmod 700 "${USER_HOME}/.ssh" 2>/dev/null || true

# Data volume layout.
mkdir -p /srv/projects /srv/data /srv/dbs /srv/extra
chown "${EXTUSER}:${EXTUSER}" /srv/projects /srv/data /srv/extra
chown root:root /srv/dbs
chmod 0755 /srv/dbs
