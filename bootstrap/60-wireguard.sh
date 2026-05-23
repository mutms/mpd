#!/bin/bash
# bootstrap/60-wireguard.sh
#
# Configure the in-VM WireGuard server end. Gated on the presence of
# /var/lib/mpd/conf/wireguard/mpd0.conf — that file is pushed in from outside
# the VM by the host-side orchestrator (e.g. mpd-virt-macos) BEFORE
# bootstrap runs.
#
# When the conf is absent (sandbox VM, or a managed VM whose host hasn't
# pushed config yet), this step is a clean no-op.
#
# When the conf is present:
#   1. Persist net.ipv4.ip_forward=1 via a sysctl.d drop-in. Required so
#      the VM kernel routes packets from wg0 (the Mac peer) into the
#      podman1 bridge and out to container IPs.
#   2. Install the conf to /etc/wireguard/mpd0.conf (root:root, 0600).
#      Only re-copy if the destination differs — avoids needless
#      service restarts on bootstrap re-runs.
#   3. enable + start wg-quick@mpd0.service. Restart if the conf changed.
#
# The `wireguard` apt package was already installed by
# 40-install-software.sh, so `wg-quick` is on PATH by the time this
# runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/00-common.sh"

IN_VM_CONF=/var/lib/mpd/conf/wireguard/mpd0.conf
SYSTEM_CONF=/etc/wireguard/mpd0.conf
WG_SERVICE=wg-quick@mpd0.service

step "WireGuard tunnel"

if [ ! -f "${IN_VM_CONF}" ]; then
    ok "no ${IN_VM_CONF} present — skipping (sandbox or pre-push state)"
    exit 0
fi

# --- ip_forward via sysctl.d drop-in ---------------------------------
IP_FORWARD_DROP_IN=/etc/sysctl.d/99-mpd-wg.conf
IP_FORWARD_BODY="# mpd: required so the kernel routes packets from wg0 → podman1 → containers.
net.ipv4.ip_forward = 1
"
if [ -f "${IP_FORWARD_DROP_IN}" ] && \
   [ "$(sudo cat "${IP_FORWARD_DROP_IN}" 2>/dev/null || true)" = "${IP_FORWARD_BODY}" ]; then
    ok "${IP_FORWARD_DROP_IN} already in place"
else
    printf '%s' "${IP_FORWARD_BODY}" | sudo install -m 644 /dev/stdin "${IP_FORWARD_DROP_IN}"
    sudo sysctl --load="${IP_FORWARD_DROP_IN}" >/dev/null
    ok "wrote + applied ${IP_FORWARD_DROP_IN}"
fi

# --- Install conf to /etc/wireguard/ ---------------------------------
# `cmp -s` exits 0 iff identical (incl. destination missing → non-zero).
# Run via sudo because /etc/wireguard/mpd0.conf is root-owned 0600.
if sudo cmp -s "${IN_VM_CONF}" "${SYSTEM_CONF}" 2>/dev/null; then
    conf_changed=0
    ok "${SYSTEM_CONF} already up to date"
else
    sudo install -m 0600 -o root -g root "${IN_VM_CONF}" "${SYSTEM_CONF}"
    conf_changed=1
    ok "installed ${IN_VM_CONF} → ${SYSTEM_CONF}"
fi

# --- Enable + start (or restart on change) ---------------------------
if [ "${conf_changed}" = 1 ]; then
    sudo systemctl enable "${WG_SERVICE}" >/dev/null
    sudo systemctl restart "${WG_SERVICE}"
    ok "${WG_SERVICE} active (conf installed)"
else
    sudo systemctl enable --now "${WG_SERVICE}" >/dev/null
    ok "${WG_SERVICE} already active (conf unchanged)"
fi
