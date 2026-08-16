#!/bin/bash
# bootstrap/40-install-software.sh
#
# apt-install everything the in-VM `mpd` binary depends on at run time:
# runtime essentials (podman + friends), DNS diagnostics, build deps for
# `make install`, plus a couple of niceties. Idempotent: apt-get install
# on already-satisfied packages is a fast no-op.
#
# Base set only. Packages for features mpd manages are apt-installed by
# `mpd --vm-setup` preflight instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/00-common.sh"

# --- DNS sanity check ---------------------------------------------------
# The platform bootstrap (sandbox/adoption prep script, or cloud-init)
# reconfigured networking not long ago. If DNS is broken — e.g.
# networkd hasn't pushed DNS to systemd-resolved yet — apt-get update
# below would fail with "Temporary failure resolving". Probe once, try
# to recover by restarting networkd + resolved, then die loud if it
# still doesn't work.

step "DNS reachability"
if getent hosts deb.debian.org >/dev/null 2>&1; then
    ok "DNS works (deb.debian.org resolves)"
else
    warn "DNS not working — restarting systemd-networkd + systemd-resolved"
    sudo systemctl restart systemd-networkd
    sleep 1
    sudo systemctl restart systemd-resolved
    dns_ok=0
    for _ in $(seq 1 30); do
        if getent hosts deb.debian.org >/dev/null 2>&1; then
            dns_ok=1
            break
        fi
        sleep 1
    done
    [ "${dns_ok}" = 1 ] \
        || die "DNS still broken after restart. Inspect: resolvectl status; networkctl status"
    ok "DNS recovered after restart"
fi

step "Installing software via apt"

# --- Package set --------------------------------------------------------
# Networking config + diagnostics, and what `make install` needs. podman
# and friends are not here: mpd installs its own run-time packages in
# `--vm-setup` preflight (go/internal/vm/host.go).
#
# bind9-dnsutils is the real package for dig/host on Trixie (dnsutils
# is virtual; dpkg-query against the virtual name always reports
# not-installed).
RUNTIME_PKGS=(
    sudo openssl bash coreutils git iputils-ping ca-certificates systemd
    iproute2 jq bind9-dnsutils traceroute tcpdump lsof curl less psmisc
)

# Build deps for `make install`. golang-go builds the mpd binary.
# libnss3-tools provides `certutil` for the Chromium NSS trust DB, which
# `mpd --vm-setup` writes the local CA into.
BUILD_PKGS=(
    build-essential pkg-config make golang-go libnss3-tools
)

# qemu-guest-agent improves hypervisor↔guest integration on KVM/Parallels.
# avahi-daemon advertises <hostname>.local over mDNS, which is how
# `mpd-virt adopt <NNN>` finds a box when no IP is given. Both are
# harmless where the hypervisor or network ignores them.
EXTRA_PKGS=(
    qemu-guest-agent
    avahi-daemon
)

ALL_PKGS=("${RUNTIME_PKGS[@]}" "${BUILD_PKGS[@]}" "${EXTRA_PKGS[@]}")

missing=()
for pkg in "${ALL_PKGS[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done

if [ ${#missing[@]} -eq 0 ]; then
    ok "all ${#ALL_PKGS[@]} packages already installed"
else
    apt_get update -qq
    apt_get install -y --no-install-recommends \
        "${missing[@]}"
    ok "installed ${#missing[@]} package(s): ${missing[*]}"
fi

step "Guest integration services"
# Debian enables+starts avahi-daemon on install; converge explicitly so a
# box where it was stopped or disabled still comes back. Not fatal: on an
# exotic box mDNS discovery just won't work and adoption takes an
# explicit IP instead.
if sudo systemctl enable --now avahi-daemon >/dev/null 2>&1; then
    ok "avahi-daemon active ($(hostname -s).local over mDNS)"
else
    warn "avahi-daemon could not be enabled — mDNS discovery unavailable"
fi
# qemu-guest-agent has no [Install] section on Debian — udev starts it
# when the hypervisor's virtio-serial device exists, and does so on
# every boot. This start only matters for the current boot.
#
# Gated on the device rather than attempted-and-caught: the unit is
# BindsTo= + After= its .device unit, and a device unit that no udev
# event will ever activate has no job timeout. `systemctl start` on a
# box without the device therefore does not fail — it blocks forever,
# which is how adoption hung on an Apple-virtualisation guest.
if [ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]; then
    if sudo systemctl start qemu-guest-agent >/dev/null 2>&1; then
        ok "qemu-guest-agent running"
    else
        warn "qemu-guest-agent did not start — inspect: systemctl status qemu-guest-agent"
    fi
else
    ok "qemu-guest-agent installed (idle — no hypervisor device on this box)"
fi
