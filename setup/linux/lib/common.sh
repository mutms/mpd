#!/bin/bash
# common.sh — shared constants and helpers for the linux platform.
# Source from every lib/*.sh script:
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
#
# Sister to setup/macos/lib/common.sh — same shape,
# Linux-ized: virsh + libvirt instead of utmctl + AppleScript;
# `ip route` instead of macOS's `route`; systemd-resolved drop-in
# instead of /etc/resolver/; ca-certificates + NSS DB instead of
# /Library/Keychains/System.keychain.

# --- Constants ---

MPD_REPO="https://github.com/mutms/mpd.git"
VM_NAME_PREFIX="mpd-machine-"

LIBVIRT_URI="qemu:///system"
LIBVIRT_NETWORK="default"                 # libvirt's stock NAT network on virbr0
BRIDGE_SUBNET="192.168.122"               # virbr0 fixed by libvirt
BRIDGE_GATEWAY="${BRIDGE_SUBNET}.1"

CONTAINER_SUBNET_PREFIX="10.163.0.0/24"
CONTAINER_PROBE_IP="10.163.0.3"           # any IP in the subnet — used for `ip route get`
DNSMASQ_IP="10.163.0.3"
DNS_DOMAIN="mpd.test"

CA_SUBJECT_MATCH="mpd.test local development CA"

# Trust-store paths (Linux)
SYSTEM_TRUST_DIR="/usr/local/share/ca-certificates"
SYSTEM_TRUST_CERT="${SYSTEM_TRUST_DIR}/mpd-test.crt"
NSSDB_DIR="${HOME}/.pki/nssdb"
NSSDB_CERT_NICKNAME="mpd-rootCA"
RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
RESOLVED_DROPIN_FILE="${RESOLVED_DROPIN_DIR}/mpd-test.conf"
FIREFOX_POLICIES_DIR="/etc/firefox/policies"
FIREFOX_POLICIES_FILE="${FIREFOX_POLICIES_DIR}/policies.json"
# Cert lives alongside policies.json so snap Firefox can read it. Snap's
# bind-mount permits /etc/firefox/policies/ but generally not /usr/local/share/.
FIREFOX_POLICIES_CERT="${FIREFOX_POLICIES_DIR}/mpd-rootCA.crt"

# Platform state — dotfile, matches macos so Swift's
# Mpd.Environment.mpdMachineCARootDir resolves uniformly across hosts.
STATE_DIR="${HOME}/.mpd-machine"
STATE_CA_FILE="${STATE_DIR}/ca.sha1"
SSH_CONFIG="${HOME}/.ssh/config"

# VM disks live in a system path so libvirtd can reach them without us
# loosening $HOME's mode. The user's subdir is owned by $USER so qemu-img
# and genisoimage can write without sudo; the parent is root-owned so
# users on a multi-user box can't accidentally trample each other.
# Both dirs are created by the preflight sudo recipe.
LIBVIRT_POOL_NAME="mpd-machine-${USER}"
LIBVIRT_POOL_PARENT="/var/lib/mpd-machine/${USER}"
LIBVIRT_POOL_DIR="${LIBVIRT_POOL_PARENT}/disks"

# Desktop launcher locations (written by setup.sh; uninstall.sh removes)
DESKTOP_APPS_DIR="${HOME}/.local/share/applications"
DESKTOP_APPS_SHORTCUT="${DESKTOP_APPS_DIR}/mpd-machine.desktop"
DESKTOP_USER_SHORTCUT="${HOME}/Desktop/mpd-machine.desktop"

# Cloud image URL — Debian Trixie generic-cloud amd64 (host arch).
# The VM is x86_64 on Ubuntu+KVM; arm64 host support can come later.
CLOUD_BASE="https://cloud.debian.org/images/cloud/trixie/20260501-2465"
CLOUD_ARCHIVE="debian-13-genericcloud-amd64-20260501-2465.tar.xz"

# --- Output helpers ---

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
warn() { printf '    warn: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# --- VM discovery (libvirt / virsh) ---

# Echoes "<name>\t<state>" per line for every VM whose name starts with
# the prefix. virsh list output:
#   Id   Name              State
#   -------------------------------
#    -   mpd-machine-158   shut off
#    1   mpd-machine-160   running
get_mpd_vms() {
    command -v virsh >/dev/null 2>&1 || return 0
    virsh -c "$LIBVIRT_URI" list --all 2>/dev/null \
        | awk -v prefix="$VM_NAME_PREFIX" '
            NR <= 2 { next }
            NF >= 3 {
                name = $2
                state = ""
                for (i = 3; i <= NF; i++) state = (state == "" ? $i : state " " $i)
                if (name ~ ("^" prefix "[0-9]+$")) printf "%s\t%s\n", name, state
            }
          ' \
        | sort
}

# virsh state strings — "running", "paused", "shut off", "in shutdown",
# "saved" (managed-saved), "crashed", "pmsuspended".
get_vm_state() {
    local name="$1"
    command -v virsh >/dev/null 2>&1 || { echo "missing"; return; }
    virsh -c "$LIBVIRT_URI" domstate "$name" 2>/dev/null || echo "missing"
}

vm_exists() {
    local name="$1"
    command -v virsh >/dev/null 2>&1 \
        && virsh -c "$LIBVIRT_URI" dominfo "$name" >/dev/null 2>&1
}

extract_octet() {
    local name="$1"
    local prefix_len=${#VM_NAME_PREFIX}
    local rest="${name:prefix_len}"
    # Always exit 0 so callers under `set -e` (e.g. octet=$(extract_octet …))
    # don't crash when the VM name has a non-numeric suffix.
    if [[ "$rest" =~ ^[0-9]+$ ]]; then
        echo "$rest"
    fi
    return 0
}

# --- Active VM detection ---
# `ip route show 10.163.0.0/24` returns the explicit route line if present,
# empty otherwise. The gateway IP is the VM IP.
get_current_vm_octet() {
    local out gw
    out=$(ip route show "$CONTAINER_SUBNET_PREFIX" 2>/dev/null) || return 0
    [ -z "$out" ] && return 0
    gw=$(awk '$1 == "'$CONTAINER_SUBNET_PREFIX'" { for (i=2;i<=NF;i++) if ($i=="via") { print $(i+1); exit } }' <<<"$out")
    if [[ "$gw" =~ ^${BRIDGE_SUBNET//./\\.}\.([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# SSH user for a VM. Lookup order: state file, ssh config, host login fallback.
get_vm_ssh_user() {
    local name="$1"
    local envfile="${STATE_DIR}/${name}.env"
    if [ -f "$envfile" ]; then
        local v
        v=$(awk -F= '/^MPD_VM_USER=/ { sub(/^MPD_VM_USER=/, ""); print; exit }' "$envfile")
        [ -n "$v" ] && { echo "$v"; return; }
    fi
    if [ -f "$SSH_CONFIG" ]; then
        local v
        v=$(awk -v target="$name" '
            $1 == "Host" {
                in_block = 0
                for (i = 2; i <= NF; i++) if ($i == target) in_block = 1
                next
            }
            in_block && tolower($1) == "user" { print $2; exit }
        ' "$SSH_CONFIG")
        [ -n "$v" ] && { echo "$v"; return; }
    fi
    whoami | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-'
}

# --- known_hosts cleanup ---
# Strip stale host keys for any address mpd reuses across VM rebuilds.
# Same intent as macos; bridge subnet differs (192.168.122 vs 64).
clear_known_hosts() {
    local known="${HOME}/.ssh/known_hosts"
    [ -f "$known" ] || return 0
    local tmp
    tmp=$(mktemp)
    awk '
        $0 ~ /^10\.163\.0\./       { next }
        $0 ~ /\.mpd\.test/         { next }
        $0 ~ /^192\.168\.122\./    { next }
        $0 ~ /^mpd-machine-/       { next }
        { print }
    ' "$known" > "$tmp" && mv "$tmp" "$known"
    chmod 600 "$known" 2>/dev/null || true
}

# --- SSH helpers ---

ssh_cmd() {
    local host="$1" user="$2"
    shift 2
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes "${user}@${host}" "$@"
}

wait_for_ssh() {
    local host="$1" user="$2" timeout="${3:-300}"
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o BatchMode=yes \
               "${user}@${host}" true 2>/dev/null; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        if [ $((elapsed % 30)) -eq 0 ]; then
            echo "    Still waiting... (${elapsed}s / ${timeout}s)"
        fi
    done
    return 1
}

# --- VM control via virsh ---

vm_start() {
    # `virsh start` auto-restores from managedsave if present; otherwise boots fresh.
    virsh -c "$LIBVIRT_URI" start "$1"
}

vm_suspend() {
    # managedsave = serialize state to disk + power off. Next `start` resumes.
    virsh -c "$LIBVIRT_URI" managedsave "$1"
}

vm_force_stop() {
    # Instant power-off (SIGKILL-equivalent). Use only when shutdown is stuck.
    virsh -c "$LIBVIRT_URI" destroy "$1"
}

vm_shutdown_graceful() {
    # ACPI shutdown — VM acks, runs shutdown sequence, powers off cleanly.
    virsh -c "$LIBVIRT_URI" shutdown "$1"
}

vm_delete() {
    # `--remove-all-storage` deletes attached qcow2 disks too. `--managed-save`
    # removes the saved state if any. Neither flag is harmful when the
    # corresponding artifact is absent.
    virsh -c "$LIBVIRT_URI" undefine "$1" --remove-all-storage --managed-save \
        --snapshots-metadata --nvram 2>/dev/null \
        || virsh -c "$LIBVIRT_URI" undefine "$1"
}

# --- ~/.ssh/config block ---
# Managed with explicit start/end markers so re-runs are idempotent.

SSH_BLOCK_START="# >>> mpd-machine (managed by linux) >>>"
SSH_BLOCK_END="# <<< mpd-machine <<<"

set_mpd_ssh_config() {
    local vm_name="$1" vm_ip="$2" vm_user="$3"
    local dir="${HOME}/.ssh"
    mkdir -p "$dir"
    chmod 700 "$dir"
    : >> "$SSH_CONFIG"

    local tmp
    tmp=$(mktemp)
    awk -v s="$SSH_BLOCK_START" -v e="$SSH_BLOCK_END" '
        $0 == s { in_block = 1; next }
        in_block && $0 == e { in_block = 0; next }
        !in_block { print }
    ' "$SSH_CONFIG" > "$tmp"

    awk '
        /^$/ { blanks = blanks $0 "\n"; next }
        { printf "%s%s\n", blanks, $0; blanks = "" }
    ' "$tmp" > "${tmp}.x"
    mv "${tmp}.x" "$tmp"

    {
        cat "$tmp"
        [ -s "$tmp" ] && echo
        echo "$SSH_BLOCK_START"
        echo "Host mpd-machine $vm_name"
        echo "    HostName $vm_ip"
        echo "    User $vm_user"
        echo "    StrictHostKeyChecking no"
        echo "$SSH_BLOCK_END"
    } > "$SSH_CONFIG"

    rm -f "$tmp"
    chmod 600 "$SSH_CONFIG"
    ok "SSH config: 'ssh mpd-machine' -> $vm_ip ($vm_user)"
}

remove_mpd_ssh_config() {
    [ -f "$SSH_CONFIG" ] || return 0
    local tmp
    tmp=$(mktemp)
    awk -v s="$SSH_BLOCK_START" -v e="$SSH_BLOCK_END" '
        $0 == s { in_block = 1; next }
        in_block && $0 == e { in_block = 0; next }
        !in_block { print }
    ' "$SSH_CONFIG" > "$tmp"
    mv "$tmp" "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG"
}

# --- ~/.mpd-machine/ state files ---

write_mpd_current_env() {
    local vm_name="$1" vm_ip="$2" vm_user="$3"
    mkdir -p "$STATE_DIR"
    local content
    content=$(printf 'MPD_VM_NAME=%s\nMPD_VM_IP=%s\nMPD_VM_USER=%s\n' \
                     "$vm_name" "$vm_ip" "$vm_user")
    printf '%s' "$content" > "${STATE_DIR}/${vm_name}.env"
    printf '%s' "$content" > "${STATE_DIR}/current.env"
    ok "current.env updated ($vm_name at $vm_ip)"
}

read_current_env_field() {
    local key="$1" file="${STATE_DIR}/current.env"
    [ -f "$file" ] || return 0
    awk -F= -v k="$key" '$1 == k { sub("^"k"=", ""); print; exit }' "$file"
}

# --- Desktop launcher (.desktop files) ---
# Two locations:
#   ~/.local/share/applications/mpd-machine.desktop — shows up in GNOME
#     activities overview, gnome-shell launcher, KRunner, etc. Auto-trusted.
#   ~/Desktop/mpd-machine.desktop — for users who have GNOME desktop icons
#     enabled (the "Desktop Icons NG" extension; on by default in Ubuntu).
#     Marked trusted via `gio set ... metadata::trusted true`.
#
# The Exec= line targets ptyxis (Ubuntu 26.04's default terminal). KDE/XFCE
# users edit the line manually — documented in the README.

ensure_desktop_shortcut() {
    local connect_sh="${SCRIPT_DIR}/connect.sh"
    [ -f "$connect_sh" ] || warn "connect.sh not at $connect_sh — desktop shortcut will fail when clicked"

    mkdir -p "$DESKTOP_APPS_DIR"
    local payload
    payload=$(cat <<EOF
[Desktop Entry]
Type=Application
Name=mpd-machine
Comment=SSH into the active mpd-machine VM
Exec=ptyxis --new-window --title=mpd-machine -- bash -lc '${connect_sh}'
Icon=utilities-terminal
Categories=Development;System;
Terminal=false
EOF
)
    printf '%s\n' "$payload" > "$DESKTOP_APPS_SHORTCUT"
    chmod 0755 "$DESKTOP_APPS_SHORTCUT"
    update-desktop-database "$DESKTOP_APPS_DIR" >/dev/null 2>&1 || true

    if [ -d "${HOME}/Desktop" ]; then
        printf '%s\n' "$payload" > "$DESKTOP_USER_SHORTCUT"
        chmod 0755 "$DESKTOP_USER_SHORTCUT"
        # GNOME 'Desktop Icons NG' refuses to launch unless the file is
        # marked trusted. No-op on KDE/XFCE.
        gio set "$DESKTOP_USER_SHORTCUT" metadata::trusted true 2>/dev/null || true
    fi
    ok "Desktop launcher: $DESKTOP_APPS_SHORTCUT (and ~/Desktop if present)"
}

remove_desktop_shortcut() {
    rm -f "$DESKTOP_APPS_SHORTCUT" "$DESKTOP_USER_SHORTCUT"
    update-desktop-database "$DESKTOP_APPS_DIR" >/dev/null 2>&1 || true
}

# --- CA generation (host-side) ---
# Bash twin of Mpd.Environment.Certificate.generateCA in
# mpd/Environment/Certificate.swift, identical to the version in
# macos/lib/common.sh. KEEP IN SYNC across all three.

generate_mpd_ca() {
    local key_path="$1" cert_path="$2"
    local conf
    conf=$(mktemp -t mpd-ca-conf.XXXXXX)
    cat > "$conf" <<'EOF'
[ req ]
distinguished_name = req_dn
x509_extensions    = v3_ca
prompt             = no

[ req_dn ]
O  = mpd.test local development CA
CN = mpd.test local development CA

[ v3_ca ]
basicConstraints       = critical, CA:TRUE, pathlen:0
subjectKeyIdentifier   = hash
keyUsage               = critical, keyCertSign, cRLSign
nameConstraints        = critical, @name_constraints

[ name_constraints ]
permitted;DNS.0        = .mpd.test
permitted;DNS.1        = mpd.test
EOF
    openssl genrsa -out "$key_path" 4096 >/dev/null 2>&1 \
        || { rm -f "$conf"; die "openssl genrsa failed"; }
    openssl req -new -x509 -key "$key_path" -out "$cert_path" -days 3650 -config "$conf" >/dev/null 2>&1 \
        || { rm -f "$conf"; die "openssl req failed"; }
    rm -f "$conf"
    chmod 600 "$key_path"
    chmod 644 "$cert_path"
}

# --- CA ---
# ~/.mpd-machine/ca/{rootCA.pem,rootCA-key.pem} — generated by setup.sh on
# the Ubuntu host before VM creation. configure-client.sh reads from here.

HOST_CA_PEM=""
HOST_CA_KEY=""

prepare_host_ca() {
    local platform_caroot="${STATE_DIR}/ca"
    local platform_pem="${platform_caroot}/rootCA.pem"
    local platform_key="${platform_caroot}/rootCA-key.pem"

    if [ -f "$platform_pem" ] && [ -f "$platform_key" ]; then
        HOST_CA_PEM="$platform_pem"
        HOST_CA_KEY="$platform_key"
        ok "reusing host CA at ${platform_caroot}"
        return 0
    fi

    mkdir -p "$platform_caroot"
    chmod 700 "$platform_caroot"
    generate_mpd_ca "$platform_key" "$platform_pem"
    HOST_CA_PEM="$platform_pem"
    HOST_CA_KEY="$platform_key"
    ok "generated host CA at ${platform_caroot}"
}

# --- Idempotent host-side privileged ops ---
# Predicate `*_needs_update` returns 0 when the operation is needed,
# 1 when current state is already correct. Matching `apply_*` performs
# the privileged action.

# Route to container subnet via VM IP.
route_needs_update() {
    local target_ip="$1"
    local out gw
    out=$(ip route show "$CONTAINER_SUBNET_PREFIX" 2>/dev/null)
    [ -z "$out" ] && return 0
    gw=$(awk '$1 == "'$CONTAINER_SUBNET_PREFIX'" { for (i=2;i<=NF;i++) if ($i=="via") { print $(i+1); exit } }' <<<"$out")
    [ "$gw" = "$target_ip" ] && return 1
    return 0
}

apply_route() {
    local target_ip="$1"
    sudo ip route replace "$CONTAINER_SUBNET_PREFIX" via "$target_ip"
}

# systemd-resolved drop-in for *.mpd.test → dnsmasq inside the VM.
# Both the desired-content function and the file content go through
# `$()` in needs_update so trailing-newline handling stays symmetric.
resolver_dropin_desired() {
    cat <<EOF
[Resolve]
DNS=${DNSMASQ_IP}
Domains=~mpd.test
EOF
}

resolver_needs_update() {
    [ -f "$RESOLVED_DROPIN_FILE" ] || return 0
    [ "$(cat "$RESOLVED_DROPIN_FILE" 2>/dev/null)" = "$(resolver_dropin_desired)" ] && return 1
    return 0
}

apply_resolver() {
    sudo install -d -m 0755 "$RESOLVED_DROPIN_DIR"
    resolver_dropin_desired | sudo tee "$RESOLVED_DROPIN_FILE" >/dev/null
    sudo chmod 0644 "$RESOLVED_DROPIN_FILE"
    # Always `restart`, not `reload`. `reload` re-parses config drop-ins
    # but doesn't reset systemd-resolved's internal "is this server
    # reachable" state, which causes 20-30s query timeouts when an
    # upstream DNS server is being added or moved. `restart` is ~50ms
    # of DNS unavailability for a guaranteed-clean state.
    sudo systemctl restart systemd-resolved
}

# Cert SHA-1 fingerprint (uppercase hex, no separators).
ca_fingerprint() {
    local cert_path="$1"
    openssl x509 -fingerprint -sha1 -noout -in "$cert_path" 2>/dev/null \
        | awk -F= '{ print $2 }' | tr -d ':' | tr 'a-f' 'A-F'
}

# System trust bundle (read by curl, wget, etc. — not Firefox).
ca_in_systrust() {
    local cert_path="$1"
    [ -f "$SYSTEM_TRUST_CERT" ] && cmp -s "$cert_path" "$SYSTEM_TRUST_CERT"
}

apply_ca_to_systrust() {
    local cert_path="$1"
    sudo install -m 0644 "$cert_path" "$SYSTEM_TRUST_CERT"
    sudo update-ca-certificates >/dev/null
    record_ca_fingerprint "$cert_path"
}

# NSS DB at ~/.pki/nssdb — read by Chromium/Chrome/Edge on Linux.
# `certutil -L -n NAME -r` exports the cert in DER directly; sha1sum of
# that DER is the SHA-1 fingerprint. Comparing fingerprints is robust
# against PEM re-encoding differences between openssl and NSS.
ca_in_nssdb() {
    local cert_path="$1"
    command -v certutil >/dev/null 2>&1 || return 1
    [ -f "${NSSDB_DIR}/cert9.db" ] || return 1
    local source_fp nssdb_fp
    source_fp=$(ca_fingerprint "$cert_path")
    [ -n "$source_fp" ] || return 1
    nssdb_fp=$(certutil -d "sql:${NSSDB_DIR}" -L -n "$NSSDB_CERT_NICKNAME" -r 2>/dev/null \
        | sha1sum 2>/dev/null | awk '{ print $1 }' | tr 'a-f' 'A-F')
    [ -z "$nssdb_fp" ] && return 1
    [ "$source_fp" = "$nssdb_fp" ]
}

apply_ca_to_nssdb() {
    local cert_path="$1"
    mkdir -p "$NSSDB_DIR"
    if [ ! -f "${NSSDB_DIR}/cert9.db" ]; then
        certutil -d "sql:${NSSDB_DIR}" -N --empty-password
    fi
    certutil -d "sql:${NSSDB_DIR}" -D -n "$NSSDB_CERT_NICKNAME" 2>/dev/null || true
    certutil -d "sql:${NSSDB_DIR}" -A -n "$NSSDB_CERT_NICKNAME" -t "C,," -i "$cert_path"
}

# Firefox enterprise policy — picked up by snap and apt Firefox alike.
# Cert lives at $FIREFOX_POLICIES_CERT (alongside policies.json) rather
# than /usr/local/share/ca-certificates/, because snap Firefox's bind-mount
# of /etc/firefox/policies covers the cert path but generally not /usr/local.
# Single-line JSON so the string passed to a manual `printf '%s\n' '...'`
# recipe is byte-equal to what `apply_firefox_policies` writes (otherwise
# needs_update flips back to "needs apply" on every run).
firefox_policies_desired() {
    printf '{"policies":{"Certificates":{"Install":["%s"]}}}\n' "$FIREFOX_POLICIES_CERT"
}

# Takes the source cert path so we can also confirm the cert next to
# policies.json matches the host CA byte-for-byte.
firefox_policies_needs_update() {
    local cert_path="$1"
    [ -f "$FIREFOX_POLICIES_FILE" ] || return 0
    [ "$(cat "$FIREFOX_POLICIES_FILE" 2>/dev/null)" = "$(firefox_policies_desired)" ] || return 0
    [ -f "$FIREFOX_POLICIES_CERT" ] || return 0
    cmp -s "$cert_path" "$FIREFOX_POLICIES_CERT" 2>/dev/null && return 1
    return 0
}

apply_firefox_policies() {
    local cert_path="$1"
    sudo install -d -m 0755 "$FIREFOX_POLICIES_DIR"
    sudo install -m 0644 "$cert_path" "$FIREFOX_POLICIES_CERT"
    firefox_policies_desired | sudo tee "$FIREFOX_POLICIES_FILE" >/dev/null
    sudo chmod 0644 "$FIREFOX_POLICIES_FILE"
}

# Always record the trusted CA's SHA-1 in $STATE_CA_FILE so uninstall.sh
# can find and remove this exact cert later.
record_ca_fingerprint() {
    local cert_path="$1"
    local fp
    fp=$(ca_fingerprint "$cert_path")
    if [ -n "$fp" ]; then
        mkdir -p "$STATE_DIR"
        printf '%s\n' "$fp" > "$STATE_CA_FILE"
    fi
}

# --- print_sudo_recipe ---
# Present the privileged commands the script is about to run and let the dev
# choose between running them in another terminal or letting the script sudo.
# Returns 0 unconditionally; the caller MUST re-run its predicate checks
# afterward to determine what (if anything) still needs sudo.
#
# Args: each command as a separate string. The function appends a final
# bare `sudo -k` so the dev's terminal also drops cached creds.
print_sudo_recipe() {
    echo
    echo "    The following commands need to run as root:"
    echo
    for cmd in "$@"; do
        printf '        %s\n' "$cmd"
    done
    printf '        %s\n' "sudo -k"
    echo
    echo "    (The trailing 'sudo -k' invalidates your cached sudo credential"
    echo "    after the recipe completes — same fence the script applies on"
    echo "    its own privileged block.)"
    echo
    echo "    You can either:"
    echo "      (a) Open another terminal, run the recipe yourself, and press Enter here."
    echo "      (b) Press Enter and let this script sudo for you (you'll be asked for your password)."
    echo
    read -r -p "    Press Enter to continue: " _
}
