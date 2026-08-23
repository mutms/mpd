#!/bin/bash
# bootstrap/20-install-software.sh
#
# Step 2 of 3. Wgettable, self-contained. Brings the operating system
# current and installs every package mpd needs — to build itself, to run
# (podman, dnsmasq, caddy, WireGuard, …), to diagnose networking, and the
# guest-integration conveniences (avahi mDNS, qemu-guest-agent).
#
# This is the ONE package list. `mpd --vm-setup` only verifies that the
# binaries are there (go/internal/vm/host.go) and points back here when
# one is missing — it never installs anything itself. When mpd gains a
# run-time dependency, add it here and to that verification table.
#
# Where it runs:
#   - on a fresh box, as step 2 of adoption / the sandbox script
#   - ahead of time in a template VM (hostname mpd-template[-<suffix>]),
#     so every clone adopts in the time of step 3 alone, and reports its
#     IP to the hypervisor (qemu-guest-agent) and over mDNS (avahi)
#   - at image-build time of mpd-virt's Apple-container image, as root:
#     the per-command `sudo` below is then a no-op elevation
#   - again on every `mpd-virt update` — a template or image that has
#     gone stale converges here
#
# No hostname gate: the OCI build has a random hostname, and step 1 has
# already validated a VM. Needs passwordless sudo (step 1). Idempotent:
# a current box costs one `apt-get update` + a `dist-upgrade` that finds
# nothing.
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

# --- apt wrapper ------------------------------------------------------
# DPkg::Lock::Timeout: Debian's built-in 120 s default is scoped to the
# `apt` command, not `apt-get`, which gives up the instant the lock is
# busy. On a desktop-flavoured box that is a near-certainty: GNOME's
# packagekitd grabs the lock to check for updates at exactly the moment
# bootstrap wants it. Waiting is right — the competing job is short and
# nobody is here to retry by hand.
#
# Acquire::Retries: this step fetches a few hundred megabytes; one
# stalled CDN connection must not fail the whole run.
#
# force-confdef/confold: dist-upgrade may meet a changed conffile. With
# no terminal to answer on, keep the installed version rather than hang.
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

# --- Gates --------------------------------------------------------------
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

# --- Operating system ---------------------------------------------------
step "apt-get update + dist-upgrade"
apt_get update -qq
apt_get dist-upgrade -y -qq
ok "operating system current"

# --- Package set --------------------------------------------------------
# Base tooling, networking config + diagnostics, and what `make install`
# needs. bind9-dnsutils is the real package for dig/host on Trixie
# (dnsutils is virtual; dpkg -s against the virtual name always reports
# not-installed). Go is not here: 30-mpd-build.sh installs upstream Go.
# libnss3-tools provides certutil for the Chromium NSS trust DB that
# `mpd --vm-setup` writes the CA into.
BASE_PKGS=(
    sudo openssl bash coreutils git wget curl ca-certificates systemd
    iproute2 iputils-ping bind9-dnsutils traceroute tcpdump lsof less psmisc
    jq build-essential pkg-config make libnss3-tools
)

# What mpd itself needs at run time.
#   podman + catatonit (the pod pause binary) + uidmap (newuidmap/newgidmap):
#     the pieces podman needs but does not pull in under
#     --no-install-recommends. Deliberately not aardvark-dns: mpd's network
#     is created with --disable-dns, and podman's own resolver would bind
#     port 53 on the gateway, where mpd's resolver listens.
#   nftables: the VM firewall.
#   wireguard-tools + wireguard-go: the encrypted host↔VM overlay
#     (mpd-virt / mpd-proxy). wireguard-go is the userspace fallback
#     wg-quick picks when the kernel has no WireGuard module (Apple
#     containers); real VMs leave it installed but unused.
#   dnsmasq-base, not dnsmasq: the binary alone. The `dnsmasq` package adds
#     a second unit reading /etc/dnsmasq.conf, the sysadmin's file, not mpd's.
#   caddy: the TLS frontdoor for `mpd --web`.
#   vim, not vim-tiny: vim-tiny ships no defaults.vim and starts in
#     compatible mode, where arrow keys insert ABCD.
RUNTIME_PKGS=(
    podman catatonit uidmap nftables
    wireguard-tools wireguard-go
    dnsmasq-base caddy vim
)

# Tools for AI agents working on the VM, which is otherwise worse
# equipped than the runtime. shellcheck/shfmt lint mpd's own shell.
# Deliberately not `gh`: it does nothing until `gh auth login`, and that
# stores a token on the VM; mpd keeps no credentials.
AGENT_PKGS=(
    shellcheck shfmt ripgrep tree
)

# Guest integration. avahi-daemon advertises <hostname>.local over mDNS,
# which is how `mpd-virt adopt <NNN>` finds a box when no IP is given.
# qemu-guest-agent lets KVM-family hypervisors (Proxmox, UTM,
# virt-manager) read the guest's IP. Both idle harmlessly where the
# hypervisor or network ignores them.
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

# --- Guest integration services -----------------------------------------
# Enable always (symlinks only — works in an OCI build with no systemd
# running); start only when systemd is PID 1 on this box. Not fatal: on
# an exotic box mDNS discovery just won't work and adoption takes an
# explicit IP instead.
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

# qemu-guest-agent has no [Install] section on Debian — udev starts it
# when the hypervisor's virtio-serial device exists, on every boot. This
# start only matters for the current boot.
#
# Gated on the device rather than attempted-and-caught: the unit is
# BindsTo= + After= its .device unit, and a device unit that no udev
# event will ever activate has no job timeout. `systemctl start` on a
# box without the device therefore does not fail — it blocks forever,
# which is how adoption once hung on an Apple-virtualisation guest.
if [ "${systemd_running}" = 1 ] && [ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]; then
    if sudo systemctl start qemu-guest-agent >/dev/null 2>&1; then
        ok "qemu-guest-agent running"
    else
        warn "qemu-guest-agent did not start — inspect: systemctl status qemu-guest-agent"
    fi
else
    ok "qemu-guest-agent installed (idle — no hypervisor device on this VM)"
fi
