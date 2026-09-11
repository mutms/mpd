#!/bin/bash
# bootstrap/00-reset-vm-clone.sh
#
# Give a cloned Debian VM a fresh identity: hostname, machine-id and
# SSH host keys. Run it on the clone, as your dev user, then reboot.
#
#   bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/bootstrap/00-reset-vm-clone.sh) mpd-<NNN>

set -euo pipefail

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

NEW_HOSTNAME="${1:-}"
case "${NEW_HOSTNAME}" in
    mpd-[0-9][0-9][0-9]) ;;
    *) die "usage: $(basename "$0") mpd-<NNN>   (3-digit id, e.g. mpd-137)" ;;
esac

[ "$(id -u)" -ne 0 ] || die "run this as your dev user, not root."
sudo -n true 2>/dev/null \
    || die "Passwordless sudo not configured. Run 10-passwordless-sudo.sh first."

step "Hostname → ${NEW_HOSTNAME}"
OLD_HOSTNAME="$(hostname -s 2>/dev/null || cut -d. -f1 /etc/hostname | tr -d '[:space:]')"
sudo hostnamectl set-hostname "${NEW_HOSTNAME}"
if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sudo sed -i -E "/^127\.0\.1\.1[[:space:]]/s/\b${OLD_HOSTNAME}\b/${NEW_HOSTNAME}/g" /etc/hosts
else
    printf '127.0.1.1\t%s\n' "${NEW_HOSTNAME}" | sudo tee -a /etc/hosts >/dev/null
fi
ok "was '${OLD_HOSTNAME}', /etc/hostname and /etc/hosts updated"

step "machine-id"
sudo rm -f /etc/machine-id /var/lib/dbus/machine-id
sudo systemd-machine-id-setup >/dev/null
sudo ln -s /etc/machine-id /var/lib/dbus/machine-id
ok "new id $(cat /etc/machine-id)"

step "SSH host keys"
if dpkg -s openssh-server >/dev/null 2>&1; then
    sudo rm -f /etc/ssh/ssh_host_*
    sudo ssh-keygen -A >/dev/null
    ok "regenerated: $(sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')"
else
    ok "openssh-server not installed — nothing to regenerate"
fi

MAC="$(ip -o link show | awk -F'link/ether ' '/link\/ether/ && !/mpdbr|veth/ {split($2,a," "); print a[1]; exit}')"
echo
echo "================================================================"
echo "  ${NEW_HOSTNAME} identity reset. Reboot now:"
echo
echo "      sudo reboot"
echo
echo "  The MAC address (${MAC:-unknown}) belongs to the hypervisor and"
echo "  is copied on clone. Give this VM a new one in its settings"
echo "  before it runs next to the original."
echo "================================================================"
