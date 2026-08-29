#!/bin/bash
# bootstrap/20-install-software.sh
#
# Step 2 of 3, wgettable and self-contained: bring the OS current and
# install every package mpd needs. This is the ONE package list —
# `mpd --vm-setup` only verifies the binaries exist
# (go/internal/vm/host.go) and never installs anything; a new run-time
# dependency goes here and into that table.
#
# No hostname gate: this also runs at OCI image build, where the
# hostname is random and step 1 has already validated a VM.
# Needs passwordless sudo (step 1). Idempotent.
#
# Environment overrides:
#   MPD_APT_LOCK_TIMEOUT  seconds to wait for the dpkg lock (default 300)
#   MPD_APT_RETRIES       retries for stalled downloads (default 3)
#
#   bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/bootstrap/20-install-software.sh)

set -euo pipefail

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
warn() { printf '    warn: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# DPkg::Lock::Timeout: apt's 120 s lock wait does not apply to apt-get,
# which gives up at once — and GNOME's packagekitd grabs the lock right
# after login. Acquire::Retries: one stalled CDN connection must not
# fail the run. force-confdef/confold: with no terminal to answer a
# conffile prompt, keep the installed version rather than hang.
MPD_APT_LOCK_TIMEOUT="${MPD_APT_LOCK_TIMEOUT:-300}"
MPD_APT_RETRIES="${MPD_APT_RETRIES:-3}"
apt_get() {
    sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get -o DPkg::Lock::Timeout="${MPD_APT_LOCK_TIMEOUT}" \
                -o Acquire::Retries="${MPD_APT_RETRIES}" \
                -o Dpkg::Options::=--force-confdef \
                -o Dpkg::Options::=--force-confold \
                "$@"
}

step "OS gate"
[ -r /etc/os-release ] || die "/etc/os-release missing — cannot verify OS."
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "debian" ] && [ "${VERSION_CODENAME:-}" = "trixie" ] \
    || die "bootstrap targets Debian Trixie (got ID=${ID:-?} VERSION_CODENAME=${VERSION_CODENAME:-?})."
ok "Debian Trixie"

step "Sudo precondition"
sudo -n true 2>/dev/null \
    || die "Passwordless sudo not configured. Run 10-passwordless-sudo.sh first."
ok "sudo -n true works"

step "apt-get update + dist-upgrade"
apt_get update -qq
apt_get dist-upgrade -y -qq
ok "operating system current"

# Base tooling and build needs. bind9-dnsutils, not dnsutils: the latter
# is virtual and dpkg -s always reports it not-installed. Go is not
# here: 30-mpd-build.sh installs upstream Go. libnss3-tools provides
# certutil for the Chromium NSS trust DB `mpd --vm-setup` writes to.
BASE_PKGS=(
    sudo openssl bash coreutils git wget curl ca-certificates systemd
    iproute2 iputils-ping bind9-dnsutils traceroute tcpdump lsof less psmisc
    jq build-essential pkg-config make libnss3-tools
)

# What mpd needs at run time.
# catatonit + uidmap: podman needs them but does not pull them in under
#   --no-install-recommends. Deliberately no aardvark-dns: mpd's network
#   uses --disable-dns, and podman's resolver would take port 53 on the
#   gateway where mpd's resolver listens.
# wireguard-go: userspace fallback for kernels without WireGuard (Apple
#   containers); real VMs leave it unused.
# dnsmasq-base, not dnsmasq: the binary alone. The dnsmasq package adds a
#   second unit reading /etc/dnsmasq.conf, the sysadmin's file.
# vim, not vim-tiny: vim-tiny starts in compatible mode, where arrow
#   keys insert ABCD.
RUNTIME_PKGS=(
    podman catatonit uidmap nftables
    wireguard-tools wireguard-go
    dnsmasq-base caddy vim
)

# Tools for AI agents working on the VM. Deliberately no `gh`: it needs
# `gh auth login`, which stores a token, and mpd keeps no credentials.
AGENT_PKGS=(
    shellcheck shfmt ripgrep tree
)

# avahi-daemon advertises <hostname>.local over mDNS, which is how
# `mpd-virt adopt` finds a box when no IP is given. qemu-guest-agent
# lets KVM-family hypervisors read the guest's IP. Both idle harmlessly
# where the hypervisor or network ignores them.
GUEST_PKGS=(
    avahi-daemon qemu-guest-agent
)

ALL_PKGS=("${BASE_PKGS[@]}" "${RUNTIME_PKGS[@]}" "${AGENT_PKGS[@]}" "${GUEST_PKGS[@]}")

step "Package set (${#ALL_PKGS[@]} packages)"
missing=()
for pkg in "${ALL_PKGS[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if [ ${#missing[@]} -eq 0 ]; then
    ok "all installed"
else
    apt_get install -y -qq --no-install-recommends "${missing[@]}"
    ok "installed ${#missing[@]}: ${missing[*]}"
fi

# Enable always (symlinks only, works in an OCI build); start only when
# systemd is PID 1. Not fatal: without mDNS, adoption takes an explicit IP.
step "Guest integration services"
systemd_running=0
[ -d /run/systemd/system ] && systemd_running=1

if sudo systemctl enable avahi-daemon >/dev/null 2>&1; then
    if [ "${systemd_running}" = 1 ]; then
        if sudo systemctl start avahi-daemon >/dev/null 2>&1; then
            ok "avahi-daemon active ($(hostname -s).local over mDNS)"
        else
            warn "avahi-daemon enabled but did not start — inspect: systemctl status avahi-daemon"
        fi
    else
        ok "avahi-daemon enabled (systemd not running here — starts on boot)"
    fi
else
    warn "avahi-daemon could not be enabled — mDNS discovery unavailable"
fi

# qemu-guest-agent has no [Install] on Debian; udev starts it when the
# virtio-serial device exists. Gate on the device, never
# attempt-and-catch: without the device, the unit's BindsTo= .device
# dependency has no job timeout, so `systemctl start` blocks forever
# instead of failing.
if [ "${systemd_running}" = 1 ] && [ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]; then
    if sudo systemctl start qemu-guest-agent >/dev/null 2>&1; then
        ok "qemu-guest-agent running"
    else
        warn "qemu-guest-agent did not start — inspect: systemctl status qemu-guest-agent"
    fi
else
    ok "qemu-guest-agent installed (idle — no hypervisor device on this VM)"
fi
