#!/bin/bash
# bootstrap/40-install-software.sh
#
# apt-install everything the in-VM `mpd` binary depends on at run time:
# runtime essentials (podman + friends), DNS diagnostics, build deps for
# `make install`, plus a couple of niceties. Idempotent: apt-get install
# on already-satisfied packages is a fast no-op.
#
# After this script completes, `mpd --setup` should never need apt
# itself — it just asserts these packages are present and fails loudly if
# any are missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/00-common.sh"

step "Installing software via apt"

# --- Package set --------------------------------------------------------
# `catatonit` is a Recommends of podman (pause binary for pods) — pulled
# explicitly because we use --no-install-recommends. aardvark-dns is
# similarly the resolver podman uses for container-name → IP; without it,
# `--dns` on Podman networks is silently dropped. bind9-dnsutils is the
# real package for dig/host on Trixie (dnsutils is virtual; dpkg-query
# against the virtual name always reports not-installed).
RUNTIME_PKGS=(
    podman catatonit aardvark-dns nftables sudo openssl
    bash coreutils git iputils-ping ca-certificates systemd iproute2 jq
    bind9-dnsutils traceroute tcpdump lsof curl less vim-tiny psmisc
)

# Build deps for `make install`. swiftlang ships the Swift toolchain on
# Trixie. libnss3-tools provides `certutil` for the Chromium NSS trust DB
# (used by mpd --setup later).
BUILD_PKGS=(
    build-essential pkg-config make swiftlang libnss3-tools
)

# qemu-guest-agent improves hypervisor↔guest integration on KVM/Parallels.
# Harmless on hypervisors that ignore it. wireguard is the apt name for
# the WG kernel module + wg-quick userspace; needed when mpd --setup finds
# a pushed WG conf and configures wg-quick@mpd0.
EXTRA_PKGS=(
    qemu-guest-agent wireguard
)

ALL_PKGS=("${RUNTIME_PKGS[@]}" "${BUILD_PKGS[@]}" "${EXTRA_PKGS[@]}")

missing=()
for pkg in "${ALL_PKGS[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done

if [ ${#missing[@]} -eq 0 ]; then
    ok "all ${#ALL_PKGS[@]} packages already installed"
else
    sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
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
