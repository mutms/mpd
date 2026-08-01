#!/bin/bash
# common.sh -- bash helpers for the windows platform.
# Sourced from scripts run inside WSL Debian via Invoke-WSLScript in common.ps1.
# All file paths passed in are /mnt/c/... translations of Windows paths.
# Do NOT set -euo pipefail here; callers own their own shell options.

# --- Output helpers ---

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
warn() { printf '    warn: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# --- WSL dependency setup ---
# Installs Linux tools needed for host-side provisioning. Idempotent.

ensure_wsl_deps() {
    local need=()
    command -v openssl     >/dev/null 2>&1 || need+=(openssl)
    command -v genisoimage >/dev/null 2>&1 || need+=(genisoimage)
    command -v qemu-img    >/dev/null 2>&1 || need+=(qemu-utils)
    if [ ${#need[@]} -eq 0 ]; then
        ok "WSL tools already installed"
        return 0
    fi
    ok "Installing: ${need[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get -qq update
    DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "${need[@]}"
}

# --- CA generation ---
# generate_mpd_ca KEY_PATH CERT_PATH
#
# Bash twin of cert.GenerateCA in go/internal/cert/ca.go.
# DN, v3_ca extensions, and nameConstraints must stay in sync with the Go
# version so mpd --vm-setup can detect and reuse a host-generated CA.

generate_mpd_ca() {
    local key_path="$1" cert_path="$2"
    local conf
    conf=$(mktemp --suffix=.conf)
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
    openssl genrsa -out "$key_path" 4096 2>/dev/null \
        || { rm -f "$conf"; die "openssl genrsa failed"; }
    openssl req -new -x509 -key "$key_path" -out "$cert_path" \
        -days 3650 -config "$conf" 2>/dev/null \
        || { rm -f "$conf"; die "openssl req failed"; }
    rm -f "$conf"
    chmod 600 "$key_path"
    chmod 644 "$cert_path"
}

# --- Cloud-init seed ISO ---
# generate_seed_iso ISO_PATH OCTET VM_USER SSH_PUB_KEY
#
# Writes cloud-init YAML to a temp dir and creates a cidata ISO via genisoimage.
# ISO_PATH is a /mnt/c/... Windows path where the ISO will be written.

generate_seed_iso() {
    local iso_path="$1" octet="$2" vm_user="$3" ssh_pub_key="$4"
    local vm_name="mpd-${octet}"
    local vm_ip="10.164.0.${octet}"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    cat > "$tmp_dir/meta-data" <<EOF
instance-id: ${vm_name}
local-hostname: ${vm_name}
EOF

    cat > "$tmp_dir/user-data" <<EOF
#cloud-config
users:
  - name: ${vm_user}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${ssh_pub_key}

ssh_pwauth: false

write_files:
  - path: /etc/sysctl.d/99-mpd-disable-ipv6.conf
    permissions: '0644'
    content: |
      # mpd: keep all traffic on IPv4. The host route to the container
      # subnet and the host's DNS resolver drop-in for *.mpd.test are
      # IPv4-only, so IPv6 paths would bypass mpd's traffic shaping.
      net.ipv6.conf.all.disable_ipv6 = 1
      net.ipv6.conf.default.disable_ipv6 = 1
      net.ipv6.conf.lo.disable_ipv6 = 1

runcmd:
  - sysctl --load=/etc/sysctl.d/99-mpd-disable-ipv6.conf
EOF

    cat > "$tmp_dir/network-config" <<EOF
version: 2
ethernets:
  ethernet0:
    match:
      name: "eth*"
    set-name: eth0
    addresses:
      - ${vm_ip}/24
    routes:
      - to: default
        via: 10.164.0.1
    nameservers:
      addresses: [8.8.8.8, 1.1.1.1]
EOF

    genisoimage -quiet -output "$iso_path" -volid cidata -joliet -rock \
        "$tmp_dir/user-data" "$tmp_dir/meta-data" "$tmp_dir/network-config"
    rm -rf "$tmp_dir"
}
