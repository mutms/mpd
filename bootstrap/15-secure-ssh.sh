#!/bin/bash
# bootstrap/15-secure-ssh.sh
#
# Optional hardening between steps 1 and 2, wgettable and self-contained:
# one sshd drop-in that refuses root login and password auth and keeps
# public-key auth on. Refuses to disable passwords while the invoking
# user has no key in ~/.ssh/authorized_keys. No-op without
# openssh-server. Needs passwordless sudo (step 1). Idempotent.
#
#   bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/bootstrap/15-secure-ssh.sh)

set -euo pipefail

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

DROPIN="/etc/ssh/sshd_config.d/10-mpd.conf"

# Same gate as step 1: never on a workstation by accident.
step "Hostname gate"
CURRENT_HOSTNAME="$(hostname -s 2>/dev/null || cut -d. -f1 /etc/hostname | tr -d '[:space:]')"
case "${CURRENT_HOSTNAME}" in
    mpd-template|mpd-sandbox)             ;;
    mpd-template-?*|mpd-sandbox-?*)       ;;
    mpd-[0-9][0-9][0-9])                  ;;
    *) die "Refusing to run: hostname is '${CURRENT_HOSTNAME}', not an mpd VM name (mpd-NNN, mpd-template[-x], mpd-sandbox[-x])." ;;
esac
ok "hostname '${CURRENT_HOSTNAME}' accepted"

step "Sudo precondition"
sudo -n true 2>/dev/null \
    || die "Passwordless sudo not configured. Run 10-passwordless-sudo.sh first."
ok "sudo -n true works"

step "sshd"
if ! dpkg -s openssh-server >/dev/null 2>&1; then
    ok "openssh-server is not installed — nothing to secure"
    exit 0
fi
[ -d /etc/ssh/sshd_config.d ] \
    || die "/etc/ssh/sshd_config.d missing — this sshd does not read drop-ins."
ok "openssh-server installed"

step "Key for $(id -un)"
if ! grep -qE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "${HOME}/.ssh/authorized_keys" 2>/dev/null; then
    die "no public key in ${HOME}/.ssh/authorized_keys — disabling password auth now would lock you out.
From your workstation, first run:
    ssh-copy-id $(id -un)@<this VM's IP>
then re-run this script."
fi
ok "authorized key present"

# Debian's sshd_config includes sshd_config.d/*.conf first and sshd keeps
# the first value it sees, so this drop-in wins over the main file and
# over later-sorting drop-ins (cloud-init writes 50-cloud-init.conf).
step "${DROPIN}"
want="$(cat <<'EOF'
# Managed by mpd (bootstrap/15-secure-ssh.sh). Re-run that script to re-apply.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
)"
if [ -f "${DROPIN}" ] && [ "$(sudo cat "${DROPIN}")" = "${want}" ]; then
    ok "already in place"
    exit 0
fi

tmp="$(mktemp)"
printf '%s\n' "${want}" > "${tmp}"
sudo install -m 0644 -o root -g root "${tmp}" "${DROPIN}"
rm -f "${tmp}"

# Validate before reloading; a bad config must never reach sshd.
if ! sudo sshd -t; then
    sudo rm -f "${DROPIN}"
    die "sshd rejected the configuration; ${DROPIN} removed."
fi
if systemctl is-active --quiet ssh; then
    sudo systemctl reload ssh
    ok "written, sshd reloaded (root over SSH off, password auth off)"
else
    ok "written (sshd not running — applies when it starts)"
fi
