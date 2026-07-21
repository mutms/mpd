#!/bin/bash
# mpd fileaccess entrypoint.
#
# Two boot tasks before sshd: ensure the dev user exists with the host UID,
# and ensure a host key exists at the bind-mounted /etc/ssh/keys/ path so
# the SSH fingerprint is stable across container rebuilds.

set -euo pipefail

: "${EXTUSER:?EXTUSER must be set}"
: "${EXTUID:?EXTUID must be set}"

# --- User ---------------------------------------------------------------
# Create the dev user if missing. UID/GID match the host so files written
# through this container land with the right ownership on the data volume.
if ! getent passwd "${EXTUSER}" >/dev/null 2>&1; then
    if ! getent group "${EXTUID}" >/dev/null 2>&1; then
        groupadd --gid "${EXTUID}" "${EXTUSER}"
    fi
    useradd --uid "${EXTUID}" --gid "${EXTUID}" --create-home --shell /bin/bash "${EXTUSER}"
    # Set the shadow password field to `*` — "no usable password" without
    # the leading `!` that Debian's sshd (with UsePAM no) treats as a locked
    # account. `passwd -l` produces `!`/`!!` which would refuse pubkey
    # logins. With `*`, password auth is impossible but pubkey works.
    usermod -p '*' "${EXTUSER}"

    # Drop interactive ssh sessions into /srv/backups — this is the
    # human-facing point of the service. scp/sftp aren't affected
    # (they don't read .profile and use absolute paths anyway).
    HOME_DIR="$(getent passwd "${EXTUSER}" | cut -d: -f6)"
    echo 'cd /srv/backups 2>/dev/null || true' >> "${HOME_DIR}/.profile"
    chown "${EXTUID}:${EXTUID}" "${HOME_DIR}/.profile"
fi

# Make sure /home/<user> is owned by the user, not by root. Podman may have
# created it ahead of useradd as part of bind-mount target setup; sshd's
# StrictModes wants the home dir owned by the login user.
chown "${EXTUID}:${EXTUID}" "$(getent passwd "${EXTUSER}" | cut -d: -f6)"

# Ensure ~/.ssh exists with the right permissions. authorized_keys is
# bind-mounted read-only — sshd is happy with that as long as ownership
# and mode line up.
HOME_DIR="$(getent passwd "${EXTUSER}" | cut -d: -f6)"
mkdir -p "${HOME_DIR}/.ssh"
chmod 700 "${HOME_DIR}/.ssh"
chown -R "${EXTUID}:${EXTUID}" "${HOME_DIR}/.ssh" 2>/dev/null || true

# --- Data-volume ownership ----------------------------------------------
# Ensure top-level directories on the data volume exist and are owned by
# the dev user. Cheap (handful of stat/chown calls) and idempotent.
# Defensive normalization: anything that ever writes here as root (e.g.
# a misrouted sudo inside a runtime) gets corrected on the next
# fileaccess start. `/srv/backups` is the single transit point: runtime
# backup verbs write here; the dev pulls files off via this service's
# SSH/scp endpoint.
for d in projects data meta dbs backups extra; do
    install -d -o "${EXTUID}" -g "${EXTUID}" -m 0775 "/srv/${d}"
done

# --- Host keys ----------------------------------------------------------
# /etc/ssh/keys is bind-mounted from the host so keys persist across
# container rebuilds. Generate once on first run; reuse forever after.
if [ ! -f /etc/ssh/keys/ssh_host_ed25519_key ]; then
    ssh-keygen -t ed25519 -f /etc/ssh/keys/ssh_host_ed25519_key -N '' -q
fi
chmod 600 /etc/ssh/keys/ssh_host_ed25519_key
chmod 644 /etc/ssh/keys/ssh_host_ed25519_key.pub

# --- sshd ---------------------------------------------------------------
exec /usr/sbin/sshd -D -e
