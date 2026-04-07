#!/bin/bash
# provision-vm.sh
# Bootstrap helper for a fresh Debian Trixie VM before running `mpd --setup`.
#
# Two-phase flow with a reboot in between (so DNS state is always sane at
# every step that needs it):
#
#   Phase 1 — switch the host to the standardized network stack:
#     systemd-resolved (DNS sink) fed by systemd-networkd or NetworkManager.
#     Apt-installing systemd-resolved on a netinst-without-GNOME box
#     replaces /etc/resolv.conf with a stub symlink for resolved, but
#     resolved has no upstream DNS until the new link manager pushes one
#     at next boot — so DNS is broken between "phase 1 finishes" and
#     "VM has rebooted." We end phase 1 cleanly and ask the user to reboot
#     instead of trying to do anything else with broken DNS.
#
#   Phase 2 — heavy apt-installs (swiftlang, build-essential, libnss3-tools,
#     spice-*) and `make install`. Runs after reboot, when DNS is healthy.
#
# A marker file (~/Developer/mpd/conf/.provision-phase-1-done) decides which
# phase to run. The script auto-detects it; the user just runs the same
# command in both invocations.
#
# Preconditions (set up by the user before running this script — see
# generic-vm/README.md):
#   - hostname == 'mpd-machine'
#   - running as a real non-root user
#   - that user has passwordless sudo (NOPASSWD)
set -euo pipefail

HOSTNAME_REGEX='^mpd-machine(-[0-9]+)?$'
PROVISION_MARKER="$HOME/Developer/mpd/conf/.provision-phase-1-done"

# Globals populated by prompt_platform_identity (first run) or loaded from
# conf/platform.env (re-runs). Read by phase 1's network-stack helpers.
MPD_PLATFORM=""
MPD_CLIENT_OS=""
MPD_VM_IP=""
MPD_NETWORK_MODE=""        # "static" or "dhcp"
MPD_NETWORK_PREFIX=""      # static only — e.g. 24
MPD_NETWORK_GATEWAY=""     # static only
MPD_NETWORK_DNS=""         # static only

log() {
    printf '[mpd-vm] %s\n' "$*"
}

warn() {
    printf '[mpd-vm] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[mpd-vm] ERROR: %s\n' "$*" >&2
    exit 1
}

validate_hostname() {
    local current_host
    current_host="$(hostname 2>/dev/null || true)"
    if ! [[ "$current_host" =~ $HOSTNAME_REGEX ]]; then
        die "Hostname must be 'mpd-machine' or 'mpd-machine-<digits>' (e.g. 'mpd-machine-158' to match a chosen IP last-octet for side-by-side VMs).
Current hostname is '${current_host}'.

Set it during Debian install, or rename now (substitute your chosen name):
    sudo hostnamectl set-hostname mpd-machine-158
    echo '127.0.1.1   mpd-machine-158' | sudo tee -a /etc/hosts
Then log out and back in, and re-run this script."
    fi
}

# Disable SSH password authentication. Requires that a pubkey already works
# (otherwise the user locks themselves out of future logins). By the time we
# reach this step, the user has SSH'd in successfully and confirm_intent has
# fired — so we know SSH access is healthy via key. Idempotent.
harden_sshd() {
    local conf=/etc/ssh/sshd_config
    if [[ ! -r "$conf" ]]; then
        warn "${conf} not readable; skipping SSH hardening."
        return
    fi
    if grep -qE '^PasswordAuthentication[[:space:]]+no$' "$conf"; then
        log "SSH password authentication already disabled."
        return
    fi
    log "Disabling SSH password authentication"
    sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$conf"
    if ! grep -qE '^PasswordAuthentication[[:space:]]+no$' "$conf"; then
        echo "PasswordAuthentication no" | sudo tee -a "$conf" >/dev/null
    fi
    sudo systemctl reload ssh 2>/dev/null || sudo systemctl restart ssh
}

validate_not_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        die "Do not run as root. Run as your real Debian user: bash ./provision-vm.sh"
    fi
}

validate_debian_trixie() {
    if [[ ! -r /etc/os-release ]]; then
        die "/etc/os-release missing — cannot verify OS. mpd-machine targets Debian Trixie."
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "debian" ]]; then
        die "mpd-machine targets Debian. Detected: ID=${ID:-unknown}, VERSION_CODENAME=${VERSION_CODENAME:-unknown}."
    fi
    if [[ "${VERSION_CODENAME:-}" != "trixie" ]]; then
        die "mpd-machine targets Debian Trixie. Detected VERSION_CODENAME=${VERSION_CODENAME:-unknown}.

If you're on a different Debian release, package names and Swift availability
may differ — pin to Trixie or accept that you're off the supported path."
    fi
    log "OS: Debian Trixie."
}

# systemd-detect-virt returns 'none' on bare metal. Warning only — the user
# might be running on a Linux laptop allocated as a sandbox, which is fine.
# But it's a useful "are you sure?" signal: most legitimate mpd-machine users
# are inside a hypervisor.
warn_if_bare_metal() {
    if ! command -v systemd-detect-virt >/dev/null 2>&1; then
        return
    fi
    local virt
    virt="$(systemd-detect-virt 2>/dev/null || echo none)"
    if [[ "$virt" == "none" ]]; then
        warn "systemd-detect-virt reports 'none' — this looks like bare metal."
        warn "mpd-machine is intended for sandbox VMs you can wipe and rebuild. Continuing."
    else
        log "Virtualization: $virt."
    fi
}

# Passwordless sudo serves two purposes:
#   1. mpd needs it at runtime (apt installs, systemctl restart, rootful podman exec).
#   2. It's also a "this is a sandbox VM" gate. Almost nobody enables NOPASSWD
#      on a real workstation or production server, so failing this check on a
#      box where you weren't expecting to touch system config is a strong
#      signal you're on the wrong host.
validate_passwordless_sudo() {
    if sudo -n true 2>/dev/null; then
        return
    fi
    die "Passwordless sudo is required for '$(whoami)' but not configured.

This script makes invasive changes (apt installs, systemd config, root
container runtime). It is intended for an mpd-machine sandbox VM you can
wipe and rebuild — never a workstation or shared host.

If '$(hostname)' really is your sandbox VM, enable NOPASSWD sudo:

    echo \"\$USER ALL=(ALL) NOPASSWD:ALL\" | sudo tee /etc/sudoers.d/\$USER
    sudo chmod 440 /etc/sudoers.d/\$USER

Then re-run this script. If running this command makes you uneasy on the
host you're typing it on, you're on the wrong host."
}

# Last gate before any modification. Lists exactly what the script will change
# and asks the user to type back the hostname. Catches the "wrong terminal"
# class of accident — pasting the bootstrap command into a session you thought
# was the VM but is actually the host.
#
# Skipped on re-runs (when platform.env is already populated) so iterating on
# a known-good VM doesn't require re-typing the hostname every time.
confirm_intent() {
    local platform_env="$HOME/Developer/mpd/conf/platform.env"
    if [[ -f "$platform_env" ]] && grep -q '^MPD_PLATFORM=' "$platform_env"; then
        log "Re-run detected (platform.env present) — skipping intent confirmation."
        return
    fi

    cat <<EOF

────────────────────────────────────────────────────────────────────
  PROVISION VM: $(hostname)
────────────────────────────────────────────────────────────────────
This script is about to modify '$(hostname)'. It runs in two phases
with a reboot in between:

  Phase 1 (this run):
    • disable SSH password authentication (sshd_config) — pubkey only
    • prompt for client OS, network mode (static/dhcp), and (when static)
      VM IP / prefix / gateway / DNS — defaults are auto-detected from
      the host's current routing; press Enter to accept each
    • write conf/platform.env
    • apt-install systemd-resolved (if missing)
    • standardize the host network stack to systemd-resolved fed by
      either NetworkManager or systemd-networkd, depending on what the
      install profile already uses; on a Trixie netinst-without-GNOME
      this means migrating ifupdown+dhcpcd → systemd-networkd. Static
      IP (when chosen) is written into the chosen link manager's config.
    • Reboot. (If nothing changed, skips the reboot and runs phase 2
      immediately in the same invocation.)

  Phase 2 (after reboot, same script re-run):
    • apt-install: build-essential, pkg-config, make, swiftlang,
      git, curl, libnss3-tools, spice-vdagent, spice-webdavd
    • run 'make install' which writes ~/Developer/mpd/bin/mpd
    • symlink /usr/local/bin/mpd → that binary
    • run 'mpd --setup' automatically (CA, podman network, services,
      laptop client recipe). Idempotent — safe to re-run.

────────────────────────────────────────────────────────────────────
  This VM is a SANDBOX with relaxed security (passwordless sudo,
  self-signed CA in trust store, persistent SSH keys).
  Do not store confidential data inside.
────────────────────────────────────────────────────────────────────
EOF
    local typed current_host
    current_host="$(hostname 2>/dev/null || true)"
    read -r -p "Type the hostname '${current_host}' to continue: " typed
    if [[ "$typed" != "$current_host" ]]; then
        die "Confirmation mismatch ('$typed' != '$current_host'). Aborting."
    fi
}

# ─── Phase 1 — switch network stack to standardized state ─────────────

# Tracked across phase 1 helpers. Set to 1 if any guarded operation actually
# changed system state. Phase 1 only triggers a reboot when this is 1, so
# idempotent re-runs (everything already in the desired state) just fall
# through to phase 2 in the same invocation.
PHASE_1_DID_ANYTHING=0

# Apt-install systemd-resolved if missing. Its postinst replaces
# /etc/resolv.conf with a stub symlink that points at resolved — but until
# the new link manager pushes upstream DNS to resolved (post-reboot), DNS is
# dead. That's why this is fenced inside phase 1 and the script exits with
# a reboot prompt afterwards instead of attempting more apt work.
install_systemd_resolved_if_missing() {
    if dpkg -s systemd-resolved >/dev/null 2>&1; then
        return
    fi
    log "Installing systemd-resolved (DNS will be broken until reboot — that is expected)"
    sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        systemd-resolved
    PHASE_1_DID_ANYTHING=1
}

# Standardize the host DNS sink to systemd-resolved fed by some link manager.
# mpd --setup expects `systemd-resolved` to be active and (post-reboot) for
# /etc/resolv.conf to be the resolved stub-resolv.conf symlink. Three branches:
#   - ifupdown active (Trixie netinst-without-GNOME default): write a generic
#     systemd-networkd .network file matching ethernet links, disable
#     networking.service for next boot, enable networkd. Wins over NM-active
#     because networking.service being enabled is a hard "we came from netinst"
#     signal; standardizing on networkd here is lighter than keeping NM around.
#   - NetworkManager active (GNOME, KDE, manual NM, ifupdown already gone):
#     write a NM conf.d snippet (`dns=systemd-resolved`) so NM hands DNS off
#     to resolved instead of writing /etc/resolv.conf directly. NM's existing
#     connection profiles are not touched.
#   - systemd-networkd active (cloud-init, macos-utm, already-converted netinst):
#     idempotent no-op.
# In all branches: enable systemd-resolved + disable networking.service +
# comment out non-loopback iface stanzas in /etc/network/interfaces, so the
# per-interface `ifup@<iface>.service` units (hotplug-triggered, NOT gated by
# networking.service) also stop spawning dhcpcd at boot.
standardize_network_stack() {
    local nm_active=0 networkd_active=0 ifupdown_enabled=0
    systemctl is-active --quiet NetworkManager     && nm_active=1       || true
    systemctl is-active --quiet systemd-networkd   && networkd_active=1 || true
    systemctl is-enabled --quiet networking 2>/dev/null && ifupdown_enabled=1 || true

    if [[ $nm_active -eq 1 && $networkd_active -eq 1 ]]; then
        die "Both NetworkManager and systemd-networkd are active. Pick one and disable the other, then re-run."
    fi
    if [[ $nm_active -eq 0 && $networkd_active -eq 0 && $ifupdown_enabled -eq 0 ]]; then
        die "No active link manager (NetworkManager / systemd-networkd / ifupdown). Configure networking first, then re-run."
    fi

    # Always: enable systemd-resolved for next boot.
    if ! systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
        log "Enabling systemd-resolved (will start on next boot)"
        sudo systemctl enable systemd-resolved >/dev/null
        PHASE_1_DID_ANYTHING=1
    fi

    # Always: disable ifupdown's networking.service for next boot if it's
    # enabled, AND comment out non-loopback iface stanzas in
    # /etc/network/interfaces. `disable` (not `stop`) — `stop` would run
    # `ifdown` and drop the live SSH session.
    if [[ $ifupdown_enabled -eq 1 ]]; then
        log "Disabling ifupdown's networking.service (will not run on next boot)"
        sudo systemctl disable networking >/dev/null 2>&1 || true
        PHASE_1_DID_ANYTHING=1
    fi
    if [[ -f /etc/network/interfaces ]] \
       && grep -qE '^(auto|allow-hotplug|iface)[[:space:]]+(en|eth)' /etc/network/interfaces; then
        log "Commenting out non-loopback ifupdown stanzas in /etc/network/interfaces"
        # Match auto/allow-hotplug/iface lines for ethernet (en* / eth*) only;
        # leave loopback (`lo`) and any user customizations alone. Tag with a
        # marker so the change is reversible by hand.
        sudo sed -i.mpd-bak -E \
            's@^(auto|allow-hotplug|iface)[[:space:]]+(en[^[:space:]]*|eth[^[:space:]]*)([[:space:]].*)?$@# mpd-disabled: \0@' \
            /etc/network/interfaces
        PHASE_1_DID_ANYTHING=1
    fi

    # Branch selection.
    if [[ $ifupdown_enabled -eq 1 ]]; then
        local nd_conf=/etc/systemd/network/10-mpd-ethernet.network
        local nd_content
        nd_content="$(build_networkd_content)"
        if [[ ! -f $nd_conf ]] || ! diff -q <(printf '%s' "$nd_content") "$nd_conf" >/dev/null 2>&1; then
            log "Writing systemd-networkd config: $nd_conf (mode=${MPD_NETWORK_MODE})"
            sudo mkdir -p /etc/systemd/network
            printf '%s' "$nd_content" | sudo install -D -m 644 /dev/stdin "$nd_conf"
            PHASE_1_DID_ANYTHING=1
        fi
        if ! systemctl is-enabled --quiet systemd-networkd 2>/dev/null; then
            log "Enabling systemd-networkd (will start on next boot)"
            sudo systemctl enable systemd-networkd >/dev/null
            PHASE_1_DID_ANYTHING=1
        fi
        if systemctl is-enabled --quiet NetworkManager 2>/dev/null; then
            log "Disabling NetworkManager (networkd is the chosen link manager on this profile)"
            sudo systemctl disable NetworkManager >/dev/null 2>&1 || true
            PHASE_1_DID_ANYTHING=1
        fi
        return
    fi

    if [[ $nm_active -eq 1 ]]; then
        local nm_conf=/etc/NetworkManager/conf.d/mpd-dns.conf
        local nm_content
        nm_content=$'[main]\ndns=systemd-resolved\nsystemd-resolved=true\n'
        if [[ ! -f $nm_conf ]] || ! diff -q <(printf '%s' "$nm_content") "$nm_conf" >/dev/null 2>&1; then
            log "Configuring NetworkManager to defer DNS to systemd-resolved"
            printf '%s' "$nm_content" | sudo install -D -m 644 /dev/stdin "$nm_conf"
            PHASE_1_DID_ANYTHING=1
        else
            log "NetworkManager already deferring DNS to systemd-resolved."
        fi
        apply_nm_static_if_needed
        return
    fi

    log "systemd-networkd already active — no further changes needed."
}

# Render systemd-networkd .network content based on MPD_NETWORK_MODE.
# - static: explicit Address/Gateway/DNS — networkd applies on next boot.
# - dhcp:   DHCP=yes — link manager negotiates lease at boot.
build_networkd_content() {
    if [[ "${MPD_NETWORK_MODE:-dhcp}" == "static" ]]; then
        printf '[Match]\nName=en* eth*\n\n[Network]\nAddress=%s/%s\nGateway=%s\nDNS=%s\n' \
            "$MPD_VM_IP" "$MPD_NETWORK_PREFIX" "$MPD_NETWORK_GATEWAY" "$MPD_NETWORK_DNS"
    else
        printf '[Match]\nName=en* eth*\n\n[Network]\nDHCP=yes\n'
    fi
}

# When the host is on NetworkManager and the user picked static, push the
# static config into NM's active connection profile via nmcli. NM owns the
# interface in this branch, so the .network file we'd otherwise drop into
# /etc/systemd/network/ would be ignored. nmcli changes don't take effect
# until the connection re-activates — phase 1's reboot handles that.
apply_nm_static_if_needed() {
    if [[ "${MPD_NETWORK_MODE:-dhcp}" != "static" ]]; then
        return
    fi
    if ! command -v nmcli >/dev/null 2>&1; then
        warn "nmcli not on PATH — cannot apply static IP via NetworkManager. Configure manually after reboot."
        return
    fi
    local active
    active="$(nmcli -t -f UUID,STATE connection show --active 2>/dev/null \
        | awk -F: '$2 == "activated" { print $1; exit }')"
    if [[ -z "$active" ]]; then
        warn "No active NetworkManager connection found — cannot apply static IP."
        return
    fi
    log "Applying static IP via NetworkManager (connection ${active})"
    sudo nmcli connection modify "$active" \
        ipv4.method manual \
        ipv4.addresses "${MPD_VM_IP}/${MPD_NETWORK_PREFIX}" \
        ipv4.gateway "${MPD_NETWORK_GATEWAY}" \
        ipv4.dns "${MPD_NETWORK_DNS}"
    PHASE_1_DID_ANYTHING=1
}

# Auto-rename the host so it reflects the static IP's last octet
# (e.g. mpd-machine-158 for 192.168.64.158). DHCP mode skips this — the IP
# is whatever the link manager negotiates, so there's no stable octet to
# match. Idempotent: no-op when current hostname is already the desired one.
apply_hostname_if_needed() {
    if [[ "${MPD_NETWORK_MODE:-dhcp}" != "static" ]]; then
        return
    fi
    local octet desired current
    octet="$(echo "$MPD_VM_IP" | awk -F. '{print $4}')"
    desired="mpd-machine-${octet}"
    current="$(hostname)"
    if [[ "$current" == "$desired" ]]; then
        return
    fi
    log "Renaming hostname: ${current} → ${desired}"
    sudo hostnamectl set-hostname "$desired"
    # Keep /etc/hosts 127.0.1.1 in sync so 'getent hosts <hostname>'
    # resolves locally. Replace the existing line, append if missing.
    if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
        sudo sed -i.mpd-bak -E "s|^(127\.0\.1\.1)[[:space:]]+.*|\1\t${desired}|" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$desired" | sudo tee -a /etc/hosts >/dev/null
    fi
    PHASE_1_DID_ANYTHING=1
}

phase_1_stack_switch() {
    apply_hostname_if_needed
    install_systemd_resolved_if_missing
    standardize_network_stack
    touch "$PROVISION_MARKER"
}

# ─── Phase 2 — install build prerequisites and build mpd ───────────────

# Quick smoke test: if DNS is broken (expected if phase 1 just ran but the
# user hasn't rebooted), bail out with a clear hint instead of letting apt
# fail with a confusing error 90 seconds later.
verify_dns_working() {
    if getent hosts deb.debian.org >/dev/null 2>&1; then
        return
    fi
    die "DNS resolution is not working — getent hosts deb.debian.org failed.

If you just finished phase 1, you need to reboot first:

    sudo reboot
    # ... SSH back in (note: VM IP may have changed) ...
    bash ~/Developer/mpd/mpd-machine/platforms/generic-vm/provision-vm.sh

If you didn't run phase 1 and DNS is still broken, fix it yourself:

    resolvectl status
    sudo resolvectl flush-caches
    cat /etc/resolv.conf"
}

# Heavy apt install — runs only in phase 2 when DNS is in a known-good state.
# `swiftlang` is the Debian-packaged Swift toolchain (Trixie ships 5.x).
# `make` is in build-essential but listed for clarity since `make install`
# is the very next step. `libnss3-tools` provides certutil; mpd --setup uses
# it to import the mpd CA into ~/.pki/nssdb/ so Chromium-family browsers
# trust *.mpd.test without certificate warnings (they don't read the OS
# trust store).
ensure_user_phase_packages() {
    # DEBIAN_FRONTEND=noninteractive suppresses debconf prompts (e.g. swiftlang
    # asks whether to create /usr/bin/swift symlink — default "yes" is what we
    # want). `-y` only handles apt's own confirm prompt, not debconf.
    sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential pkg-config make swiftlang \
        git curl \
        libnss3-tools
}

# SPICE guest agents — clipboard share (spice-vdagent) and host-folder share
# via WebDAV (spice-webdavd). Both are virtio-channel-driven: on a non-SPICE
# host (Apple Virt, Hyper-V, VMware, bare metal) the channel doesn't exist,
# the daemons sit idle, and nothing breaks. So installing unconditionally is
# safe — opt-in is simply "use a QEMU/SPICE-capable hypervisor."
#
# Debian's cloud/minimal images don't preinstall these; Ubuntu desktop does.
install_spice_guest_tools() {
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        spice-vdagent spice-webdavd
    log "SPICE guest tools installed (active only under QEMU/SPICE)."
}

# Ensure ~/.local/bin is on PATH for non-login shells too. Debian's default
# ~/.profile already adds it for login shells; appending to .bashrc covers
# `ssh user@host <command>` and other non-login interactive sessions where
# user-installed CLIs (Claude Code, etc.) need to resolve.
ensure_local_bin_on_path() {
    mkdir -p "$HOME/.local/bin"
    local marker='# mpd: ~/.local/bin on PATH for user-installed CLIs'
    if ! grep -qF "$marker" "$HOME/.bashrc" 2>/dev/null; then
        cat >> "$HOME/.bashrc" <<EOF

${marker}
[ -d "\$HOME/.local/bin" ] && PATH="\$HOME/.local/bin:\$PATH"
EOF
        log "Added ~/.local/bin to PATH in ~/.bashrc"
    fi
}

verify_repo_present() {
    local source_dir="$HOME/Developer/mpd"
    if [[ ! -d "${source_dir}/.git" ]]; then
        die "${source_dir} is not a git checkout.

Per the bootstrap flow (mpd-machine/platforms/generic-vm/README.md), clone
the repo yourself before running this script:

    git clone https://github.com/mutms/mpd.git ~/Developer/mpd
    bash ~/Developer/mpd/mpd-machine/platforms/generic-vm/provision-vm.sh"
    fi
    log "Repository present at ${source_dir}"
}


build_mpd() {
    local source_dir="$HOME/Developer/mpd"
    [[ -d "$source_dir" ]] || die "Missing source dir: $source_dir"

    if ! command -v swift >/dev/null 2>&1; then
        die "swift not on PATH after apt install. Check: dpkg -l swiftlang"
    fi
    log "Swift: $(swift --version | head -n1)"

    cd "$source_dir"
    log "Running make install"
    make install
}

# Symlink the built binary into /usr/local/bin so `mpd` resolves on PATH for
# every shell. Matches macos-utm/create-vm.sh. `ln -sf` is idempotent.
install_mpd_on_path() {
    local source_bin="$HOME/Developer/mpd/bin/mpd"
    [[ -x "$source_bin" ]] || die "Expected $source_bin after 'make install' but it is missing or not executable."
    sudo ln -sf "$source_bin" /usr/local/bin/mpd
    log "Installed /usr/local/bin/mpd -> ${source_bin}"
}

phase_2_install_and_build() {
    verify_dns_working
    ensure_user_phase_packages
    install_spice_guest_tools
    build_mpd
    install_mpd_on_path
    run_mpd_setup
}

# Hand off to mpd --setup once the binary is on PATH. This is what most
# users would type next anyway, and `mpd --setup` is itself idempotent +
# self-healing, so re-runs of provision-vm.sh just re-converge state.
run_mpd_setup() {
    if ! command -v mpd >/dev/null 2>&1; then
        die "mpd binary not on PATH after install_mpd_on_path."
    fi
    log "Running 'mpd --setup' (CA, podman network, services)"
    mpd --setup
}

# Auto-detect the host's current IPv4 routing parameters: default gateway,
# the interface that gateway lives on, the local IP on that interface, the
# CIDR prefix length, and an upstream DNS server. Best-effort — every value
# is just a *default* for the prompts in prompt_platform_identity, and the
# user can override anything they don't like.
DETECTED_GATEWAY=""
DETECTED_INTERFACE=""
DETECTED_IP=""
DETECTED_PREFIX=""
DETECTED_DNS=""
detect_network_params() {
    local default_route
    default_route="$(ip -4 route show default 2>/dev/null \
        | awk '/^default via/ { print $3 " " $5; exit }')"
    DETECTED_GATEWAY="$(echo "$default_route" | awk '{print $1}')"
    DETECTED_INTERFACE="$(echo "$default_route" | awk '{print $2}')"

    if [[ -n "$DETECTED_GATEWAY" ]]; then
        DETECTED_IP="$(ip -4 route get "$DETECTED_GATEWAY" 2>/dev/null \
            | grep -oP 'src \K[0-9.]+' | head -n 1)"
    fi
    if [[ -n "$DETECTED_INTERFACE" && -n "$DETECTED_IP" ]]; then
        DETECTED_PREFIX="$(ip -4 -o addr show dev "$DETECTED_INTERFACE" 2>/dev/null \
            | grep -oP 'inet \K[0-9.]+/[0-9]+' | head -n 1 | cut -d/ -f2)"
    fi

    # DNS: prefer resolvectl's "Current DNS Server" if available, else first
    # nameserver in /etc/resolv.conf, else the gateway (typical home-router
    # behavior — gateway also serves DNS).
    if command -v resolvectl >/dev/null 2>&1; then
        DETECTED_DNS="$(resolvectl status 2>/dev/null \
            | awk '/Current DNS Server:/ { print $4; exit }')"
    fi
    if [[ -z "$DETECTED_DNS" ]]; then
        DETECTED_DNS="$(awk '/^nameserver / { print $2; exit }' /etc/resolv.conf 2>/dev/null)"
    fi
    DETECTED_DNS="${DETECTED_DNS:-$DETECTED_GATEWAY}"
}

# Helper: prompt with a default value, validate, retry until accepted.
# Args: <prompt-label> <default-value> <var-name> <validator-func>
prompt_with_default() {
    local label="$1" default="$2" varname="$3" validator="$4"
    local input=""
    while [[ -z "$input" ]]; do
        read -r -p "${label} [${default}]: " input
        input="${input:-$default}"
        if ! "$validator" "$input"; then
            input=""
        fi
    done
    printf -v "$varname" '%s' "$input"
}

is_dotted_quad() {
    if [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        return 0
    fi
    warn "Not a dotted-quad IPv4 address: '$1'. Try again."
    return 1
}

is_cidr_prefix() {
    if [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 8 ] && [ "$1" -le 30 ]; then
        return 0
    fi
    warn "Prefix length must be a number 8..30 (got '$1'). Try again."
    return 1
}

is_known_client_os() {
    case "$1" in
        macos|debian|fedora|windows) return 0 ;;
    esac
    warn "Unknown client OS '$1'. Try macos/debian/fedora/windows."
    return 1
}

is_static_or_dhcp() {
    case "$1" in
        static|dhcp) return 0 ;;
    esac
    warn "Mode must be 'static' or 'dhcp' (got '$1'). Try again."
    return 1
}

prompt_platform_identity() {
    local conf_dir="$HOME/Developer/mpd/conf"
    local file="${conf_dir}/platform.env"

    # Re-run path: load existing platform.env into globals; for DHCP mode,
    # auto-update MPD_VM_IP if the live IP drifted (link-manager swap can
    # land a different lease). Static-mode IPs are assumed correct — no
    # silent overwrites.
    if [[ -f "$file" ]] \
       && grep -q '^MPD_PLATFORM=' "$file" \
       && grep -q '^MPD_CLIENT_OS=' "$file" \
       && grep -q '^MPD_VM_IP=' "$file"; then
        # shellcheck disable=SC1090
        . "$file"
        MPD_NETWORK_MODE="${MPD_NETWORK_MODE:-dhcp}"  # legacy platform.env had no mode
        if [[ "$MPD_NETWORK_MODE" == "dhcp" ]]; then
            local current_ip
            current_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -n 1)"
            [[ -z "$current_ip" ]] && current_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
            if [[ -n "$current_ip" && "$current_ip" != "$MPD_VM_IP" ]]; then
                log "VM IP changed: ${MPD_VM_IP} → ${current_ip} — updating ${file}"
                sudo sed -i "s|^MPD_VM_IP=.*|MPD_VM_IP=${current_ip}|" "$file"
                MPD_VM_IP="$current_ip"
            else
                log "Platform identity already at ${file} — skipping prompts."
            fi
        else
            log "Platform identity already at ${file} (static, ${MPD_VM_IP}/${MPD_NETWORK_PREFIX:-?}) — skipping prompts."
        fi
        return
    fi

    log "Recording platform identity (writes to ${file})."
    log "  Platform is fixed as 'generic-vm' for this script."

    detect_network_params
    if [[ -z "$DETECTED_IP" || -z "$DETECTED_GATEWAY" ]]; then
        die "Could not auto-detect IP / default gateway from 'ip route'.
Configure networking manually (a default route + an IP on its interface)
before re-running this script."
    fi
    log "Detected: IP=${DETECTED_IP}/${DETECTED_PREFIX:-?} via ${DETECTED_GATEWAY} (iface ${DETECTED_INTERFACE}), DNS=${DETECTED_DNS}"

    prompt_with_default "Client OS (macos/debian/fedora/windows)" "macos" MPD_CLIENT_OS is_known_client_os
    prompt_with_default "Network mode (static/dhcp)" "static" MPD_NETWORK_MODE is_static_or_dhcp

    if [[ "$MPD_NETWORK_MODE" == "static" ]]; then
        prompt_with_default "VM IP" "$DETECTED_IP" MPD_VM_IP is_dotted_quad
        prompt_with_default "Prefix length" "${DETECTED_PREFIX:-24}" MPD_NETWORK_PREFIX is_cidr_prefix
        prompt_with_default "Gateway" "$DETECTED_GATEWAY" MPD_NETWORK_GATEWAY is_dotted_quad
        prompt_with_default "DNS server" "$DETECTED_DNS" MPD_NETWORK_DNS is_dotted_quad
    else
        # DHCP: record the current IP so client recipes have something to
        # point at. Phase-1 reboot may land a different lease; the re-run
        # path picks up the change.
        MPD_VM_IP="$DETECTED_IP"
    fi

    mkdir -p "$conf_dir"
    {
        echo "# mpd platform identity — written by provision-vm.sh."
        echo "# Lives under conf/ so it survives \`mpd --uninstall\`."
        echo "MPD_PLATFORM=generic-vm"
        echo "MPD_CLIENT_OS=${MPD_CLIENT_OS}"
        echo "MPD_VM_IP=${MPD_VM_IP}"
        echo "MPD_NETWORK_MODE=${MPD_NETWORK_MODE}"
        if [[ "$MPD_NETWORK_MODE" == "static" ]]; then
            echo "MPD_NETWORK_PREFIX=${MPD_NETWORK_PREFIX}"
            echo "MPD_NETWORK_GATEWAY=${MPD_NETWORK_GATEWAY}"
            echo "MPD_NETWORK_DNS=${MPD_NETWORK_DNS}"
        fi
    } > "$file"
    chmod 0644 "$file"
    log "Wrote ${file} (mode=${MPD_NETWORK_MODE}, vm_ip=${MPD_VM_IP})."
}

run_user_phase() {
    log "User phase started as $(whoami)."
    verify_repo_present
    harden_sshd
    prompt_platform_identity
    ensure_local_bin_on_path

    if [[ ! -f "$PROVISION_MARKER" ]]; then
        log "Phase 1 — switching network stack."
        phase_1_stack_switch

        if [[ $PHASE_1_DID_ANYTHING -eq 1 ]]; then
            cat <<EOF

────────────────────────────────────────────────────────────────────
  PROVISION VM: $(hostname) — phase 1 complete (reboot required)
────────────────────────────────────────────────────────────────────

The host network stack has been reconfigured. DNS may be broken until
reboot — that is expected (the systemd-resolved package replaced
/etc/resolv.conf with a stub symlink, and the new link manager will
push upstream DNS to resolved only after it starts on next boot).

The VM IP may change after reboot. Once it is back up, SSH in again
(check your hypervisor's UI for the new IP if needed) and re-run:

    bash ~/Developer/mpd/mpd-machine/platforms/generic-vm/provision-vm.sh

EOF
            read -r -p "Press Enter to 'sudo reboot' now (Ctrl-C to abort): " _
            log "Rebooting…"
            sudo reboot
            # `sudo reboot` is asynchronous — the kernel takes a moment to
            # actually halt. Sleep so we don't fall through and mistakenly
            # claim a successful end-of-script before the reboot lands.
            sleep 30
            return
        fi

        log "Network stack already in standardized state — continuing to phase 2 in this run."
    fi

    log "Phase 2 — installing build prerequisites, building mpd, running mpd --setup."
    phase_2_install_and_build

    cat <<EOF

────────────────────────────────────────────────────────────────────
  PROVISION VM: $(hostname) — bootstrap complete
────────────────────────────────────────────────────────────────────

This VM is a SANDBOX with relaxed security (passwordless sudo,
self-signed CA in trust store, persistent SSH keys).
Do not store confidential data inside.

Laptop client recipe (route + DNS + CA trust) was printed by 'mpd --setup'
just above. To retrieve it again later, run:

    mpd --setup-info

EOF
}

main() {
    validate_hostname
    validate_not_root
    validate_debian_trixie
    warn_if_bare_metal
    validate_passwordless_sudo
    confirm_intent
    run_user_phase
}

main "$@"
