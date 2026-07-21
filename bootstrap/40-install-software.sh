#!/bin/bash
# bootstrap/40-install-software.sh
#
# apt-install everything the in-VM `mpd` binary depends on at run time:
# runtime essentials (podman + friends), DNS diagnostics, build deps for
# `make install`, plus a couple of niceties. Idempotent: apt-get install
# on already-satisfied packages is a fast no-op.
#
# After this script completes, `mpd --vm-setup` should never need apt
# itself — it just asserts these packages are present and fails loudly if
# any are missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/00-common.sh"

# --- DNS sanity check ---------------------------------------------------
# bootstrap/30 just reconfigured networking. If DNS is broken — e.g.
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
# `catatonit` is a Recommends of podman (pause binary for pods) — pulled
# explicitly because we use --no-install-recommends. aardvark-dns is
# similarly the resolver podman uses for container-name → IP; without it,
# `--dns` on Podman networks is silently dropped. `uidmap` provides
# newuidmap/newgidmap; rootless podman requires it for multi-ID maps
# (missing on minimal Debian images, present on full installs).
# bind9-dnsutils is the real package for dig/host on Trixie (dnsutils
# is virtual; dpkg-query against the virtual name always reports
# not-installed). Full `vim`, not `vim-tiny`: vim-tiny ships no
# defaults.vim, so it starts in compatible mode where arrow keys insert
# ABCD characters and backspace won't cross the insert point — the
# runtime containers already install full vim, and the VM should match.
RUNTIME_PKGS=(
    podman catatonit aardvark-dns uidmap nftables sudo openssl
    bash coreutils git iputils-ping ca-certificates systemd iproute2 jq
    bind9-dnsutils traceroute tcpdump lsof curl less vim psmisc
)

# Build deps for `make install`. golang-go builds the mpd binary.
# libnss3-tools provides `certutil` for the Chromium NSS trust DB, which
# `mpd --vm-setup` writes the local CA into.
BUILD_PKGS=(
    build-essential pkg-config make golang-go libnss3-tools
)

# qemu-guest-agent improves hypervisor↔guest integration on KVM/Parallels.
# Harmless on hypervisors that ignore it.
EXTRA_PKGS=(
    qemu-guest-agent
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

# --- podman-restart.service --------------------------------------------
# `--restart=always` on containers only survives a host reboot when this
# unit is enabled; without it the policy is silently ineffective.
step "podman-restart.service"
if systemctl is-enabled --quiet podman-restart.service 2>/dev/null \
   && systemctl is-active --quiet podman-restart.service 2>/dev/null; then
    ok "podman-restart.service already enabled + running"
else
    sudo systemctl enable --now podman-restart.service
    ok "podman-restart.service enabled + started"
fi
