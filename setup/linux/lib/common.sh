#!/bin/bash
# common.sh — shared constants and helpers for the linux platform.
# Source from every lib/*.sh script:
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
#
# Linux-side counterpart to the mpd-virt orchestrator
# (https://github.com/mutms/mpd-virt): same job — clone or create
# a managed Debian Trixie VM and wire the host into it — using virsh +
# libvirt, `ip route` instead of macOS's `route`, a systemd-resolved
# drop-in instead of /etc/resolver/, and ca-certificates + NSS DB
# instead of /Library/Keychains/System.keychain.

# --- Constants ---

MPD_REPO="https://github.com/mutms/mpd.git"
VM_NAME_PREFIX="mpd-"

LIBVIRT_URI="qemu:///system"
LIBVIRT_NETWORK="default"                 # libvirt's stock NAT network on virbr0
BRIDGE_SUBNET="192.168.122"               # virbr0 fixed by libvirt
BRIDGE_GATEWAY="${BRIDGE_SUBNET}.1"

# --- Container network (per-VM) ---
# Each mpd VM owns one /24 and one DNS zone, both keyed on its ID: VM 150
# serves 10.163.150.0/24 and the zone 150.mpd.test. That is what lets a
# workstation reach several VMs at once — the routes are to disjoint /24s
# and the resolver drop-ins cover disjoint domains.
#
# The VM ID is the VM's hostname suffix (mpd-<NNN>), which cloud-init
# sets; the in-VM mpd derives everything from it (net.Current).
MPD_SUBNET_PREFIX="10.163"
MPD_ROOT_DOMAIN="mpd.test"

# Placeholders — real values come from mpd_net_from_vm_ip below. Anything
# using these must call it first; they are deliberately empty so a missed
# call fails loudly instead of silently targeting some default VM.
CONTAINER_SUBNET_PREFIX=""
CONTAINER_PROBE_IP=""                     # any IP in the subnet — used for `ip route get`
DNSMASQ_IP=""
DNS_DOMAIN=""

# The CA is shared by every VM: it is name-constrained to the root domain,
# which permits any depth beneath it, so one trust operation covers every
# VM's zone. Not per-VM, deliberately.
CA_SUBJECT_MATCH="mpd.test local development CA"

# Derive this VM's network facts from its IP. Call once, early, in any
# script that touches the route, the resolver drop-in, or the zone.
mpd_net_from_vm_ip() {
    local vm_ip="$1" octet label
    octet="${vm_ip##*.}"
    [[ "$octet" =~ ^[0-9]+$ ]] && [ "$octet" -ge 100 ] && [ "$octet" -le 254 ] \
        || die "cannot derive VM id from IP '${vm_ip}' — VM ids are 100..254"
    label="$octet"
    CONTAINER_SUBNET_PREFIX="${MPD_SUBNET_PREFIX}.${octet}.0/24"
    CONTAINER_PROBE_IP="${MPD_SUBNET_PREFIX}.${octet}.3"
    DNSMASQ_IP="${CONTAINER_PROBE_IP}"
    DNS_DOMAIN="${label}.${MPD_ROOT_DOMAIN}"
    RESOLVED_DROPIN_FILE="${RESOLVED_DROPIN_DIR}/mpd-${label}.conf"
}

# Trust-store paths (Linux)
SYSTEM_TRUST_DIR="/usr/local/share/ca-certificates"
SYSTEM_TRUST_CERT="${SYSTEM_TRUST_DIR}/mpd-test.crt"
NSSDB_DIR="${HOME}/.pki/nssdb"
NSSDB_CERT_NICKNAME="mpd-rootCA"
RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
# Per-VM: mpd-150.conf, mpd-180.conf, … Each names only its own zone in
# `Domains=`, so several coexist without fighting over *.mpd.test.
# Set by mpd_net_from_vm_ip.
RESOLVED_DROPIN_FILE=""
FIREFOX_POLICIES_DIR="/etc/firefox/policies"
FIREFOX_POLICIES_FILE="${FIREFOX_POLICIES_DIR}/policies.json"
# Cert lives alongside policies.json so snap Firefox can read it. Snap's
# bind-mount permits /etc/firefox/policies/ but generally not /usr/local/share/.
FIREFOX_POLICIES_CERT="${FIREFOX_POLICIES_DIR}/mpd-rootCA.crt"

# Platform state — dotfile, matches macos so the in-VM mpd's CA-reuse
# check finds the same CA layout across hosts.
STATE_DIR="${HOME}/.mpd-virt"
STATE_CA_FILE="${STATE_DIR}/ca.sha1"
SSH_CONFIG="${HOME}/.ssh/config"

# VM disks live in a system path so libvirtd can reach them without us
# loosening $HOME's mode. The user's subdir is owned by $USER so qemu-img
# and genisoimage can write without sudo; the parent is root-owned so
# users on a multi-user box can't accidentally trample each other.
# Both dirs are created by the preflight sudo recipe.
LIBVIRT_POOL_NAME="mpd-${USER}"
LIBVIRT_POOL_PARENT="/var/lib/mpd-virt/${USER}"
LIBVIRT_POOL_DIR="${LIBVIRT_POOL_PARENT}/disks"

# Desktop launcher locations (written by setup.sh; uninstall.sh removes)
DESKTOP_APPS_DIR="${HOME}/.local/share/applications"
DESKTOP_APPS_SHORTCUT="${DESKTOP_APPS_DIR}/mpd.desktop"
DESKTOP_USER_SHORTCUT="${HOME}/Desktop/mpd.desktop"

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
#    -   mpd-158   shut off
#    1   mpd-160   running
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

# --- Routed VM detection ---
# Every routed mpd VM shows up as a 10.163.<NNN>.0/24 entry whose third
# octet IS the VM id, so the route table alone enumerates them — no need
# to map a gateway back to a VM.
#
# Several VMs can be routed at once by design. `get_current_vm_octet`
# returns the lowest, for callers that just want "a" VM to talk to;
# `get_routed_vm_octets` returns all of them.
get_routed_vm_octets() {
    ip route show 2>/dev/null | awk -v pfx="${MPD_SUBNET_PREFIX}." '
        index($1, pfx) == 1 {
            split($1, a, ".")
            print a[3]
        }' | sort -n | uniq
}

get_current_vm_octet() {
    get_routed_vm_octets | head -1
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
        $0 ~ /^mpd-/       { next }
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

SSH_BLOCK_START="# >>> mpd-vm (managed by linux) >>>"
SSH_BLOCK_END="# <<< mpd-vm <<<"

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
        echo "Host mpd-vm $vm_name"
        echo "    HostName $vm_ip"
        echo "    User $vm_user"
        echo "    StrictHostKeyChecking no"
        echo "$SSH_BLOCK_END"
    } > "$SSH_CONFIG"

    rm -f "$tmp"
    chmod 600 "$SSH_CONFIG"
    ok "SSH config: 'ssh mpd-vm' -> $vm_ip ($vm_user)"
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

# --- ~/.mpd-virt/ state files ---

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
#   ~/.local/share/applications/mpd.desktop — shows up in GNOME
#     activities overview, gnome-shell launcher, KRunner, etc. Auto-trusted.
#   ~/Desktop/mpd.desktop — for users who have GNOME desktop icons
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
Name=mpd-vm
Comment=SSH into the active mpd-vm VM
Exec=ptyxis --new-window --title=mpd-vm -- bash -lc '${connect_sh}'
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
# Bash twin of cert.GenerateCA in go/internal/cert/ca.go and the
# mpd-virt repo's Go CA generator (go/internal/ca). KEEP IN SYNC
# across all three.
#
# pathlen:1 is load-bearing. The root signs a per-VM intermediate (see
# generate_vm_ca), and a root asserting pathlen:0 may sign leaves and
# nothing else. openssl issues the intermediate happily either way; every
# client then rejects the chain, which surfaces as broken HTTPS with no
# obvious cause. A root generated before this changed has to be replaced —
# prepare_host_ca refuses to reuse one.

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
basicConstraints       = critical, CA:TRUE, pathlen:1
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

# --- Per-VM signing CA ---
# Bash twin of the per-VM CA generator in the mpd-virt repo's Go `ca`
# package (LoadOrGenerateVM in go/internal/ca).
#
# The root's private key stays on this host. What a VM gets is its own
# intermediate, name-constrained to that VM's zone, which the in-VM `mpd`
# uses to sign its service and project certificates. RFC 5280 constraints
# compose down the chain, so a leaf this CA signs for another VM's zone —
# or for a public domain — is rejected by every verifier that implements
# them. A rooted VM can forge names in its own zone and nowhere else.
#
# Args: key_path cert_path root_pem root_key octet
generate_vm_ca() {
    local key_path="$1" cert_path="$2" root_pem="$3" root_key="$4" octet="$5"
    local vm_id zone conf csr days end_date end_s now_s

    vm_id="$octet"
    zone="${vm_id}.mpd.test"

    # Nothing may outlive its issuer: a certificate valid past its CA's
    # expiry stops verifying on the CA's date while still reading as
    # valid, which is a confusing failure to debug. Cap to whatever the
    # root has left, and to the 397 days macOS accepts for a leaf.
    end_date=$(openssl x509 -in "$root_pem" -noout -enddate | cut -d= -f2)
    end_s=$(date -d "$end_date" +%s 2>/dev/null) \
        || die "could not parse root CA expiry '${end_date}'"
    now_s=$(date +%s)
    days=$(( (end_s - now_s) / 86400 ))
    [ "$days" -gt 0 ] || die "root CA at ${root_pem} has expired — regenerate it."
    [ "$days" -le 397 ] || days=397

    conf=$(mktemp -t mpd-vmca-conf.XXXXXX)
    csr=$(mktemp -t mpd-vmca-csr.XXXXXX)
    cat > "$conf" <<EOF
[ v3_intermediate ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:TRUE, pathlen:0
keyUsage               = critical, keyCertSign, cRLSign
nameConstraints        = critical, permitted;DNS:${zone}
EOF

    openssl req -new -newkey rsa:4096 -nodes \
        -keyout "$key_path" -out "$csr" \
        -subj "/CN=mpd VM ${vm_id} CA/OU=mpd-virt/O=mpd local development" \
        >/dev/null 2>&1 \
        || { rm -f "$conf" "$csr"; die "openssl req failed (VM CA)"; }

    # Serial file beside the root: it is the one place that sees every
    # certificate the root has signed, which is what stops two VMs being
    # issued the same serial.
    openssl x509 -req -in "$csr" \
        -CA "$root_pem" -CAkey "$root_key" \
        -CAserial "$(dirname "$root_pem")/rootCA.srl" -CAcreateserial \
        -sha256 -days "$days" -out "$cert_path" \
        -extfile "$conf" -extensions v3_intermediate \
        >/dev/null 2>&1 \
        || { rm -f "$conf" "$csr" "$key_path" "$cert_path"; die "openssl x509 failed (VM CA)"; }

    rm -f "$conf" "$csr"
    chmod 600 "$key_path"
    chmod 644 "$cert_path"
}

# --- CA ---
# ~/.mpd-virt/ca/{rootCA.pem,rootCA-key.pem} — generated by setup.sh on
# the Ubuntu host before VM creation. configure-client.sh reads from here.
# The private key never leaves this host; see generate_vm_ca.

HOST_CA_PEM=""
HOST_CA_KEY=""

prepare_host_ca() {
    local platform_caroot="${STATE_DIR}/ca"
    local platform_pem="${platform_caroot}/rootCA.pem"
    local platform_key="${platform_caroot}/rootCA-key.pem"

    if [ -f "$platform_pem" ] && [ -f "$platform_key" ]; then
        # A root generated before per-VM CAs asserts pathlen:0 and cannot
        # sign the intermediate every VM now gets. Fail here rather than
        # at the first TLS handshake.
        if openssl x509 -in "$platform_pem" -noout -text | grep -q 'pathlen:0'; then
            die "The host CA at ${platform_pem} asserts pathlen:0 and cannot sign
    a per-VM intermediate. It predates per-VM signing CAs.

    Remove ${platform_caroot}/ and re-run this script to generate a
    replacement, then re-trust the new CA on this host and in any VM
    that still trusts the old one."
        fi
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

# systemd-resolved drop-in for *.<zone> → dnsmasq inside that VM.
# Both the desired-content function and the file content go through
# `$()` in needs_update so trailing-newline handling stays symmetric.
resolver_dropin_desired() {
    cat <<EOF
[Resolve]
DNS=${DNSMASQ_IP}
Domains=~${DNS_DOMAIN}
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
