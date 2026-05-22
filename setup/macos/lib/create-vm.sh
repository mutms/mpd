#!/bin/bash
# create-vm.sh — Clone a Debian Trixie mpd VM from the Parallels template.
#
# Called by lib/setup.sh after the user has picked octet/user/memory/disk.
# Non-interactive (no prompts). Does not configure host networking — that
# lives in lib/configure-client.sh.
#
# Usage:
#   bash lib/create-vm.sh \
#       --octet=155 --user=skodak \
#       --ssh-pub-key="$HOME/.ssh/id_ed25519.pub" \
#       --memory-gb=12 --disk-gb=200 \
#       --host-ca-pem=... --host-ca-key=...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

# --- Args ---

VM_OCTET=""
VM_USER=""
SSH_KEY=""
VM_MEMORY_GB=""
VM_DISK_SIZE=""
ARG_HOST_CA_PEM=""
ARG_HOST_CA_KEY=""

for arg in "$@"; do
    case "$arg" in
        --octet=*)         VM_OCTET="${arg#*=}" ;;
        --user=*)          VM_USER="${arg#*=}" ;;
        --ssh-pub-key=*)   SSH_KEY="${arg#*=}" ;;
        --memory-gb=*)     VM_MEMORY_GB="${arg#*=}" ;;
        --disk-gb=*)       VM_DISK_SIZE="${arg#*=}" ;;
        --host-ca-pem=*)   ARG_HOST_CA_PEM="${arg#*=}" ;;
        --host-ca-key=*)   ARG_HOST_CA_KEY="${arg#*=}" ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

[ -n "$VM_OCTET" ]         || die "Missing --octet"
[ -n "$VM_USER" ]          || die "Missing --user"
[ -n "$SSH_KEY" ]          || die "Missing --ssh-pub-key"
[ -n "$VM_MEMORY_GB" ]     || die "Missing --memory-gb"
[ -n "$VM_DISK_SIZE" ]     || die "Missing --disk-gb"
[ -n "$ARG_HOST_CA_PEM" ]  || die "Missing --host-ca-pem (setup.sh prepares it via prepare_host_ca)"
[ -n "$ARG_HOST_CA_KEY" ]  || die "Missing --host-ca-key"
[ -f "$SSH_KEY" ]          || die "SSH public key not found: $SSH_KEY"
[ -f "$ARG_HOST_CA_PEM" ]  || die "Host CA cert not found: $ARG_HOST_CA_PEM"
[ -f "$ARG_HOST_CA_KEY" ]  || die "Host CA key not found: $ARG_HOST_CA_KEY"

# Static-IP gate. The Parallels Shared DHCP range is .1–.99 (per
# template-builder README); mpd VMs take .100+.
if [ "$VM_OCTET" -lt "$MIN_STATIC_OCTET" ] || [ "$VM_OCTET" -gt "$MAX_STATIC_OCTET" ]; then
    die "Octet ${VM_OCTET} out of range. Parallels Shared DHCP owns .1–.$(($MIN_STATIC_OCTET - 1)); pick ${MIN_STATIC_OCTET}–${MAX_STATIC_OCTET}."
fi

VM_NAME="${VM_NAME_PREFIX}${VM_OCTET}"
VM_IP="${BRIDGE_SUBNET}.${VM_OCTET}"
VM_MEMORY_MIB=$((VM_MEMORY_GB * 1024))
VM_DISK_MB=$((VM_DISK_SIZE * 1024))
VM_CPUS=4

step "Creating VM: name=${VM_NAME} ip=${VM_IP} user=${VM_USER} memory=${VM_MEMORY_GB}GB disk=${VM_DISK_SIZE}GB"

[ -x "$PRLCTL" ] || die "prlctl not found at ${PRLCTL}. Install Parallels Desktop Pro."

template_exists \
    || die "Parallels template '${TEMPLATE_NAME}' not found. Prepare it per setup/macos/README.md."

if vm_exists "$VM_NAME"; then
    die "VM '$VM_NAME' already exists in Parallels. Delete it first or pick a different octet."
fi

# --- Clone template (full clone) ---
# `--linked` would make a parent-dependent thin clone (smaller, fast).
# We default to full clones so each mpd VM is independent of the
# template's lifecycle (you can convert the template back to a VM, move
# it, delete it). Linked support can come later behind a flag.

step "Cloning template '${TEMPLATE_NAME}' (full clone — this can take a couple of minutes)"
"$PRLCTL" clone "$TEMPLATE_NAME" --name "$VM_NAME" >/dev/null \
    || die "prlctl clone failed for ${TEMPLATE_NAME} → ${VM_NAME}"

# Capture the new VM's UUID — this is the stable identifier mpd tracks
# going forward, regardless of any Parallels-side rename later.
VM_UUID=$(prlctl_uuid_of "$VM_NAME")
[ -n "$VM_UUID" ] || die "Could not read the new VM's UUID via prlctl list ${VM_NAME} -o uuid."
ok "Clone created (uuid=${VM_UUID})"

# --- Resize hardware ---

step "Configuring memory / cpus / disk"
"$PRLCTL" set "$VM_UUID" --memsize "$VM_MEMORY_MIB" >/dev/null
"$PRLCTL" set "$VM_UUID" --cpus "$VM_CPUS" >/dev/null

# Grow the primary disk if the requested size exceeds the template's. We
# rely on Parallels' guest-tools-driven online resize to push the new
# size into the partition + filesystem; if Tools aren't running or the
# resize doesn't take, the in-guest verify step later in this script
# warns but doesn't fail.
"$PRLCTL" set "$VM_UUID" --device-set hdd0 --size "$VM_DISK_MB" >/dev/null 2>&1 \
    || warn "could not resize hdd0 (template may already be ≥${VM_DISK_SIZE} GB)"
ok "Hardware: ${VM_MEMORY_GB} GB RAM, ${VM_CPUS} vCPU, ${VM_DISK_SIZE} GB disk"

# --- Start VM (template's seed user + injected SSH key get us in) ---

step "Starting VM '${VM_NAME}' (uuid=${VM_UUID})"
vm_start "$VM_UUID"
ok "VM started"

# Strip cached host keys for the IPs/names this VM will own.
clear_known_hosts
for h in "$VM_IP" "$VM_NAME"; do
    ssh-keygen -R "$h" >/dev/null 2>&1 || true
done

step "Waiting for Parallels Tools to report a DHCP-assigned IP"
DHCP_IP=$(get_vm_ip "$VM_UUID" 120) \
    || die "VM never reported an IP via Parallels Tools. Open Parallels Desktop to investigate."
ok "Guest reported IP: ${DHCP_IP}"

step "Waiting for SSH at ${DHCP_IP} (${VM_USER})"
wait_for_ssh "$DHCP_IP" "$VM_USER" 180 \
    || die "SSH not reachable at ${DHCP_IP}:22 within 180s."
ok "SSH ready (${VM_USER}@${DHCP_IP})"

# --- Inject the dev's SSH key (template-only key gets us in once; this
# ensures the dev's actual key is in authorized_keys for ongoing access).
# Idempotent — appends only if absent.

step "Authorizing dev SSH key in the VM"
SSH_PUB_KEY=$(cat "$SSH_KEY")
ssh_cmd "$DHCP_IP" "$VM_USER" "export PUBKEY=$(printf '%q' "$SSH_PUB_KEY"); bash -se" <<'EOF'
set -e
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
grep -qxF "$PUBKEY" "$HOME/.ssh/authorized_keys" || echo "$PUBKEY" >> "$HOME/.ssh/authorized_keys"
EOF
ok "Dev SSH key authorized"

# --- Rename hostname + pin static IP ---
# After this, SSH on the DHCP IP dies. We continue on the static IP.

step "Renaming hostname to ${VM_NAME} and pinning static IP to ${VM_IP}"
ssh_cmd "$DHCP_IP" "$VM_USER" \
    "export VM_NAME=$(printf '%q' "$VM_NAME") VM_IP=$(printf '%q' "$VM_IP") \
            VM_GW=$(printf '%q' "$BRIDGE_GATEWAY"); bash -se" <<'EOF'
set -e

# Hostname
sudo hostnamectl set-hostname "$VM_NAME"
sudo sed -i "s|^127\\.0\\.1\\.1.*|127.0.1.1\\t${VM_NAME}|" /etc/hosts

# Static IP via NetworkManager. The template uses NetworkManager (GNOME
# desktop default). Find the active wired connection and switch it from
# DHCP to manual.
conn=$(nmcli -t -f NAME,DEVICE,TYPE,STATE c show --active \
        | awk -F: '$3 == "802-3-ethernet" && $4 == "activated" { print $1; exit }')
if [ -z "$conn" ]; then
    echo "ERROR: no active ethernet NetworkManager connection found" >&2
    exit 1
fi

# Configure (writes /etc/NetworkManager/system-connections/<conn>.nmconnection).
# `nmcli connection modify` is idempotent at the key level.
sudo nmcli connection modify "$conn" \
    ipv4.method manual \
    ipv4.addresses "${VM_IP}/24" \
    ipv4.gateway "${VM_GW}" \
    ipv4.dns "${VM_GW}" \
    ipv6.method disabled \
    connection.autoconnect yes

# Re-up the connection. This drops our SSH session — that's expected.
# `&` + `disown` to fire-and-forget so the SSH command itself doesn't
# block on the connection going away mid-transition.
( sudo nmcli connection down "$conn" \
    && sudo nmcli connection up "$conn" ) >/dev/null 2>&1 &
disown 2>/dev/null || true

# Give the local side a moment so the parent SSH client can flush its
# buffer; the connection down happens just after.
sleep 1
EOF
ok "Hostname + static IP applied (SSH on DHCP IP is now dead by design)"

# --- Wait for SSH on the new static IP ---

step "Waiting for SSH at ${VM_IP} (post-rename)"
clear_known_hosts
for h in "$DHCP_IP" "$VM_IP" "$VM_NAME"; do
    ssh-keygen -R "$h" >/dev/null 2>&1 || true
done
wait_for_ssh "$VM_IP" "$VM_USER" 120 \
    || die "VM did not come back at ${VM_IP} within 120s."
ok "SSH ready (${VM_USER}@${VM_IP})"

# --- Disable IPv6 (mpd is IPv4-only; matches macos's cloud-init step) ---

step "Disabling IPv6 inside the guest"
ssh_cmd "$VM_IP" "$VM_USER" 'bash -se' <<'EOF'
set -e
sudo tee /etc/sysctl.d/99-mpd-disable-ipv6.conf >/dev/null <<SYSCTL
# mpd: keep all traffic on IPv4. The host route to the container subnet
# and the host's DNS resolver drop-in for *.mpd.test are IPv4-only, so
# IPv6 paths would bypass mpd's traffic shaping.
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSCTL
sudo sysctl --load=/etc/sysctl.d/99-mpd-disable-ipv6.conf >/dev/null
EOF
ok "IPv6 disabled"

# --- Ensure repo is up to date (template ships with mpd cloned + built) ---

step "Updating mpd repository in VM"
ssh_cmd "$VM_IP" "$VM_USER" "export MPD_REPO=$(printf '%q' "$MPD_REPO"); bash -se" <<'EOF'
set -e
mkdir -p "$HOME/Developer"
if [ ! -d "$HOME/Developer/mpd/.git" ]; then
    sudo apt-get -o Acquire::Retries=3 update -qq
    sudo apt-get -o Acquire::Retries=3 install -y --no-install-recommends git ca-certificates
    if ! ssh-keygen -F github.com >/dev/null 2>&1; then
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        ssh-keyscan github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
        chmod 600 "$HOME/.ssh/known_hosts"
    fi
    git clone "$MPD_REPO" "$HOME/Developer/mpd"
else
    git -C "$HOME/Developer/mpd" pull --ff-only 2>&1 | sed 's/^/    /' \
        || { echo "ERROR: git pull --ff-only failed; resolve in ~/Developer/mpd and re-run." >&2; exit 1; }
fi
EOF
ok "Repository ready"

# --- Platform identity ---

step "Writing platform identity to ~/.mpd/conf/platform.env"
VM_ID=$(printf '%03d' "$VM_OCTET")
ssh_cmd "$VM_IP" "$VM_USER" \
    "export VM_IP=$(printf '%q' "$VM_IP") VM_ID=$(printf '%q' "$VM_ID"); bash -se" <<'EOF'
set -e
mkdir -p "$HOME/.mpd/conf"
cat > "$HOME/.mpd/conf/platform.env" <<PLATFORM_EOF
# mpd platform identity — written by macos/lib/create-vm.sh.
# Lives under ~/.mpd/conf/ (persistent identity dir for the in-VM mpd binary).
MPD_PLATFORM=managed
MPD_VM_IP=${VM_IP}
MPD_VM_ID=${VM_ID}
PLATFORM_EOF
chmod 0644 "$HOME/.mpd/conf/platform.env"
EOF
ok "Platform identity recorded"

# --- Swap (only if absent — template may already have one) ---

step "Ensuring swap file (4 GB)"
ssh_cmd "$VM_IP" "$VM_USER" 'bash -se' <<'EOF'
set -e
if ! swapon --show | grep -q .; then
    if [ ! -f /swapfile ]; then
        sudo fallocate -l 4G /swapfile
        sudo chmod 600 /swapfile
        sudo mkswap /swapfile >/dev/null
    fi
    sudo swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi
EOF
ok "Swap ready"

# --- Build mpd (template likely has swiftlang already; idempotent) ---

step "Building mpd"
ssh_cmd "$VM_IP" "$VM_USER" 'bash -se' <<'EOF'
set -e
if ! command -v swift >/dev/null 2>&1 || ! dpkg -s build-essential >/dev/null 2>&1; then
    sudo apt-get -o Acquire::Retries=3 update -qq
    sudo apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        build-essential pkg-config make swiftlang
fi
cd "$HOME/Developer/mpd"
make install
sudo ln -sf "$HOME/Developer/mpd/bin/mpd" /usr/local/bin/mpd
EOF
ok "mpd built and installed"

# --- Upload host CA into VM so mpd --setup reuses it ---

step "Uploading host CA into VM"
ssh_cmd "$VM_IP" "$VM_USER" \
    "mkdir -p ~/.mpd/conf/caroot && chmod 700 ~/.mpd/conf/caroot"
scp -q -o StrictHostKeyChecking=no -o BatchMode=yes \
    "$ARG_HOST_CA_PEM" "$ARG_HOST_CA_KEY" \
    "${VM_USER}@${VM_IP}:.mpd/conf/caroot/"
ssh_cmd "$VM_IP" "$VM_USER" "chmod 600 ~/.mpd/conf/caroot/rootCA*.pem"
ok "Host CA uploaded"

# --- mpd --setup ---

step "Running 'mpd --setup' (CA, podman network, services)"
ssh_cmd "$VM_IP" "$VM_USER" 'mpd --setup'
ok "mpd --setup complete"

# --- Login banner ---

step "Setting login banner"
ssh_cmd "$VM_IP" "$VM_USER" 'bash -se' <<'EOF'
set -e
sudo chmod -x /etc/update-motd.d/* 2>/dev/null || true
sudo cp "$HOME/Developer/mpd/assets/machine/motd" /etc/motd
EOF
ok "Login banner set"

step "VM bootstrap complete"
echo "    ${VM_USER}@${VM_IP} (${VM_NAME}, uuid=${VM_UUID})"

# Surface the new UUID to setup.sh so it can write state files keyed by UUID.
# Side-channel via a known filename rather than parsing stdout — keeps the
# rest of create-vm.sh's output free to be human-readable.
if [ -n "${MPD_NEW_VM_UUID_FILE:-}" ]; then
    printf '%s\n' "$VM_UUID" > "$MPD_NEW_VM_UUID_FILE"
fi
