#!/bin/bash
# create-vm.sh — Create a single Debian Trixie VM on UTM for mpd-machine.
#
# Called by lib/setup.sh after the user has selected octet/user/memory/disk.
# This script is non-interactive (no prompts) and does not configure host
# networking — that lives in lib/configure-client.sh.
#
# Usage:
#   bash lib/create-vm.sh \
#       --octet=158 --user=skodak \
#       --ssh-pub-key="$HOME/.ssh/id_ed25519.pub" \
#       --memory-gb=12 --disk-gb=200

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

VM_NAME="${VM_NAME_PREFIX}${VM_OCTET}"
VM_IP="${BRIDGE_SUBNET}.${VM_OCTET}"
VM_MEMORY_MIB=$((VM_MEMORY_GB * 1024))
VM_CPUS=4   # configurable later in UTM (stop VM > Edit > System)

TEMP_DIR="${SCRIPT_DIR}/temp"
mkdir -p "$TEMP_DIR"

step "Creating VM: name=${VM_NAME} ip=${VM_IP} user=${VM_USER} memory=${VM_MEMORY_GB}GB disk=${VM_DISK_SIZE}GB"

if vm_exists "$VM_NAME"; then
    die "VM '$VM_NAME' already exists in UTM. Delete it first or pick a different octet."
fi

# --- Download cloud image ---

step "Preparing Debian Trixie cloud image"

CACHED_ARCHIVE="${TEMP_DIR}/${CLOUD_ARCHIVE}"
if [ -f "$CACHED_ARCHIVE" ]; then
    ok "Using cached: $(basename "$CACHED_ARCHIVE")"
else
    echo "    Downloading ${CLOUD_ARCHIVE} (~200 MB)..."
    curl -L --progress-bar -o "$CACHED_ARCHIVE" "${CLOUD_BASE}/${CLOUD_ARCHIVE}"
    ok "Downloaded: ${CLOUD_ARCHIVE}"
fi

# --- Extract + resize raw disk ---

DISK_PATH="${TEMP_DIR}/${VM_NAME}.raw"
echo "    Extracting raw disk image..."
# Clear any leftover raw images from prior runs so the freshly-extracted file
# is unambiguous (the extracted name varies by Debian release).
find "$TEMP_DIR" -maxdepth 1 \( -name "*.raw" -o -name "disk.*" \) -delete 2>/dev/null || true
tar -xJf "$CACHED_ARCHIVE" -C "$TEMP_DIR"
RAW_FILE=$(find "$TEMP_DIR" -maxdepth 1 -name "*.raw" -print -quit)
if [ -z "$RAW_FILE" ]; then
    RAW_FILE=$(find "$TEMP_DIR" -maxdepth 1 -name "disk.*" -print -quit)
fi
[ -z "$RAW_FILE" ] && die "Could not find raw disk image in archive"
mv "$RAW_FILE" "$DISK_PATH"

TARGET_BYTES=$((VM_DISK_SIZE * 1024 * 1024 * 1024))
CURRENT_BYTES=$(stat -f %z "$DISK_PATH")
if [ "$TARGET_BYTES" -lt "$CURRENT_BYTES" ]; then
    die "Requested disk size ${VM_DISK_SIZE} GB is smaller than the cloud image ($((CURRENT_BYTES / 1024 / 1024 / 1024)) GB). Pick a larger size."
fi
dd if=/dev/zero of="$DISK_PATH" bs=1 count=0 seek="$TARGET_BYTES" 2>/dev/null
ok "Disk extracted and resized to ${VM_DISK_SIZE} GB (sparse)"

# --- Cloud-init seed ISO ---

step "Creating cloud-init configuration"

SSH_PUB_KEY=$(cat "$SSH_KEY")
CIDATA_DIR="${TEMP_DIR}/cidata"
mkdir -p "$CIDATA_DIR"

cat > "${CIDATA_DIR}/meta-data" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

cat > "${CIDATA_DIR}/user-data" <<EOF
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true

users:
  - name: ${VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${SSH_PUB_KEY}

ssh_pwauth: false

growpart:
  mode: auto
  devices: ['/']

resize_rootfs: true

runcmd:
  - systemctl enable --now ssh
EOF

cat > "${CIDATA_DIR}/network-config" <<EOF
version: 2
ethernets:
  enp0s1:
    addresses: [${VM_IP}/24]
    gateway4: ${BRIDGE_GATEWAY}
    nameservers:
      addresses: [${BRIDGE_GATEWAY}]
EOF

# Volume label "cidata" required by cloud-init NoCloud datasource.
SEED_ISO="${TEMP_DIR}/seed.iso"
hdiutil makehybrid -o "$SEED_ISO" -iso -joliet -default-volume-name cidata "$CIDATA_DIR" >/dev/null 2>&1
ok "Cloud-init seed ISO created"

rm -rf "$CIDATA_DIR"

# --- Create VM in UTM ---

step "Creating VM in UTM '${VM_NAME}'"

# QEMU backend, aarch64. The primary disk is imported into the VM bundle so
# the machine does not depend on TEMP_DIR after creation. QEMU + SPICE gives
# clipboard sync, dynamic display resize, and visible DHCP leases in UTM's GUI.
osascript <<APPLESCRIPT
tell application "UTM"
    set diskFile to POSIX file "${DISK_PATH}"
    set seedFile to POSIX file "${SEED_ISO}"
    make new virtual machine with properties { ¬
        backend:qemu, ¬
        configuration:{ ¬
            name:"${VM_NAME}", ¬
            architecture:"aarch64", ¬
            memory:${VM_MEMORY_MIB}, ¬
            cpu cores:${VM_CPUS}, ¬
            drives:{ ¬
                {source:diskFile}, ¬
                {source:seedFile} ¬
            }, ¬
            network interfaces:{{mode:shared}} ¬
        } ¬
    }
end tell
APPLESCRIPT
ok "VM created"

# --- Memory ballooning ---
# UTM's QEMU backend leaves virtio-balloon off for AppleScript-created VMs,
# so the full ${VM_MEMORY_MIB} MiB sits pinned in macOS even when the guest
# is idle. Adding the balloon device with free-page-reporting lets macOS
# reclaim unused guest pages.

step "Enabling memory ballooning"

osascript <<APPLESCRIPT
tell application "UTM"
    set vm to virtual machine named "${VM_NAME}"
    set config to configuration of vm
    set qemu additional arguments of config to {{argument string:"-device"}, {argument string:"virtio-balloon-pci,free-page-reporting=on"}}
    update configuration of vm with config
end tell
APPLESCRIPT
ok "virtio-balloon-pci attached (free-page-reporting on)"

# --- Start VM (first boot — cloud-init runs) ---

step "Starting VM (cloud-init runs on first boot — takes 1-3 minutes)"
vm_start "$VM_NAME"
ok "VM started"

# Strip cached host keys for the IPs/names this VM will own; old VMs reused
# the same address space and `ssh` would otherwise reject the new keys.
clear_known_hosts
for h in "${VM_IP}" "${VM_NAME}"; do
    ssh-keygen -R "$h" >/dev/null 2>&1 || true
done

step "Waiting for SSH at ${VM_IP} (VM first boot — user creation, disk grow)"
wait_for_ssh "$VM_IP" "$VM_USER" 300 \
    || die "SSH not available after 300s. Check the VM in UTM — cloud-init may still be running."
ok "SSH ready (${VM_USER}@${VM_IP})"

step "Waiting for cloud-init to complete"
elapsed=0
timeout=300
while [ $elapsed -lt $timeout ]; do
    if ssh_cmd "$VM_IP" "$VM_USER" "test -f /var/lib/cloud/instance/boot-finished" 2>/dev/null; then
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    if [ $((elapsed % 30)) -eq 0 ]; then
        echo "    Still running... (${elapsed}s / ${timeout}s)"
    fi
done
[ $elapsed -ge $timeout ] && warn "cloud-init may not have finished. Continuing anyway..."
ok "Cloud-init complete"

# --- Verify root filesystem resize ---

step "Verifying root filesystem size"
ROOT_DEVICE=$(ssh_cmd "$VM_IP" "$VM_USER" "findmnt -n -o SOURCE /" 2>/dev/null || true)
ROOT_SIZE_GB=$(ssh_cmd "$VM_IP" "$VM_USER" "df -k / | awk 'NR==2 {printf \"%d\", int(\$2/1024/1024)}'" 2>/dev/null || true)
if [ -n "$ROOT_DEVICE" ] && [ -n "$ROOT_SIZE_GB" ]; then
    MIN_EXPECTED_GB=$((VM_DISK_SIZE - 5))
    if [ "$ROOT_SIZE_GB" -lt "$MIN_EXPECTED_GB" ]; then
        warn "root filesystem smaller than expected (${ROOT_SIZE_GB}G, target ~${VM_DISK_SIZE}G). Device: ${ROOT_DEVICE}"
    else
        ok "Root filesystem: ${ROOT_DEVICE} (${ROOT_SIZE_GB}G)"
    fi
else
    warn "could not verify root filesystem size."
fi

# --- Clone mpd repo ---

step "Cloning mpd repository in VM"

ssh_cmd "$VM_IP" "$VM_USER" "export MPD_REPO=$(printf '%q' "$MPD_REPO"); bash -se" <<'EOF'
set -e
# Debian generic cloud image is minimal — git/curl/libnss3-tools/qemu-guest-agent
# are not preinstalled. Install them now (we don't put apt installs in cloud-init
# itself because cloud-init's package phase is racy on flaky Debian mirrors;
# doing it here gives us retries and visible output).
if ! command -v git >/dev/null 2>&1; then
    echo "    installing base packages (git, curl, libnss3-tools, qemu-guest-agent)"
    sudo apt-get -o Acquire::Retries=3 update
    sudo apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        git curl libnss3-tools qemu-guest-agent
fi

mkdir -p "$HOME/Developer"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if ! ssh-keygen -F github.com >/dev/null 2>&1; then
    ssh-keyscan github.com >> "$HOME/.ssh/known_hosts"
fi
chmod 600 "$HOME/.ssh/known_hosts"

git clone "$MPD_REPO" "$HOME/Developer/mpd"
echo "    Repository cloned to $HOME/Developer/mpd"
EOF
ok "Repository ready"

# --- Platform identity ---

step "Writing platform identity to conf/platform.env"
ssh_cmd "$VM_IP" "$VM_USER" "export VM_IP=$(printf '%q' "$VM_IP"); bash -se" <<'EOF'
set -e
mkdir -p "$HOME/Developer/mpd/conf"
cat > "$HOME/Developer/mpd/conf/platform.env" <<PLATFORM_EOF
# mpd platform identity — written by macos-utm/lib/create-vm.sh.
# Lives under conf/ so it survives \`mpd --uninstall\`.
MPD_PLATFORM=macos-utm
MPD_CLIENT_OS=macos
MPD_VM_IP=${VM_IP}
PLATFORM_EOF
chmod 0644 "$HOME/Developer/mpd/conf/platform.env"
echo "    Wrote $HOME/Developer/mpd/conf/platform.env"
EOF
ok "Platform identity recorded"

# --- Detach cloud-init ISO ---

step "Detaching cloud-init CD"

ssh_cmd "$VM_IP" "$VM_USER" "sudo shutdown -h now" >/dev/null 2>&1 || true
rm -f "$DISK_PATH"
rm -f "$SEED_ISO"
ok "Temporary VM import images removed"

osascript <<APPLESCRIPT
tell application "UTM"
    set vm to virtual machine named "${VM_NAME}"
    set deadline to (current date) + 120
    repeat
        if status of vm is stopped then exit repeat
        delay 1
        if (current date) > deadline then
            stop vm
        end if
    end repeat
    set config to configuration of vm
    set vmDrives to drives of config
    set keptDrives to {}
    repeat with vmDrive in vmDrives
        if (host size of vmDrive) is not 0 then
            set end of keptDrives to vmDrive
        end if
    end repeat
    set drives of config to keptDrives
    update configuration of vm with config
end tell
APPLESCRIPT
ok "Cloud-init CD detached"

step "Restarting VM without cloud-init CD"
osascript <<APPLESCRIPT
tell application "UTM"
    set vm to virtual machine named "${VM_NAME}"
    start vm
    set deadline to (current date) + 60
    repeat
        if status of vm is started then exit repeat
        if (current date) > deadline then exit repeat
        delay 1
    end repeat
end tell
APPLESCRIPT
wait_for_ssh "$VM_IP" "$VM_USER" 300 \
    || die "VM did not come back after detaching the cloud-init CD."
ok "VM restarted"

# --- In-VM provisioning ---

step "Creating swap file (4 GB)"
ssh_cmd "$VM_IP" "$VM_USER" 'bash -se' <<'EOF'
set -e
if [ ! -f /swapfile ]; then
    sudo fallocate -l 4G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi
EOF
ok "Swap ready"

step "Installing required packages to build mpd binary"
ssh_cmd "$VM_IP" "$VM_USER" 'bash -se' <<'EOF'
set -e
sudo apt-get -o Acquire::Retries=3 update
sudo apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
    build-essential pkg-config make swiftlang
if ! command -v swift >/dev/null 2>&1; then
    echo "Swift install did not expose 'swift' on PATH" >&2
    exit 1
fi
EOF
ok "Required packages installed"

step "Building and installing mpd"
ssh_cmd "$VM_IP" "$VM_USER" 'bash -se' <<'EOF'
cd "$HOME/Developer/mpd"
make install
sudo ln -sf "$HOME/Developer/mpd/bin/mpd" /usr/local/bin/mpd
EOF
ok "mpd built and installed"

# Debian's default ~/.profile adds ~/.local/bin only for login shells. This
# covers `ssh user@host <cmd>` and other non-login interactive sessions.
step "Ensuring ~/.local/bin on PATH"
ssh_cmd "$VM_IP" "$VM_USER" 'bash -se' <<'EOF'
mkdir -p "$HOME/.local/bin"
marker='# mpd: ~/.local/bin on PATH for user-installed CLIs'
if ! grep -qF "$marker" "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" <<'BASHRC_EOF'

# mpd: ~/.local/bin on PATH for user-installed CLIs
[ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH"
BASHRC_EOF
fi
EOF
ok "~/.local/bin on PATH"

# Upload the host-side CA into the VM before `mpd --setup` runs. mpd
# detects the existing CA and reuses it (see
# mpd/Environment/Machine/MachineActionSetup.swift:331), so every VM on
# this Mac shares the same CA the macOS keychain already trusts. setup.sh
# guarantees these files exist via prepare_host_ca.

step "Uploading host CA into VM (mpd will reuse it)"
ssh_cmd "$VM_IP" "$VM_USER" \
    "mkdir -p ~/Developer/mpd/conf/caroot && chmod 700 ~/Developer/mpd/conf/caroot"
scp -q -o StrictHostKeyChecking=no -o BatchMode=yes \
    "$ARG_HOST_CA_PEM" "$ARG_HOST_CA_KEY" \
    "${VM_USER}@${VM_IP}:Developer/mpd/conf/caroot/"
ssh_cmd "$VM_IP" "$VM_USER" "chmod 600 ~/Developer/mpd/conf/caroot/rootCA*.pem"
ok "Host CA uploaded"

step "Running 'mpd --setup' (CA, podman network, services)"
ssh_cmd "$VM_IP" "$VM_USER" 'mpd --setup'
ok "mpd --setup complete"

step "Enabling mpd auto-start on VM boot"
ssh_cmd "$VM_IP" "$VM_USER" 'bash -se' <<'EOF'
set -e
sudo loginctl enable-linger "$(id -un)"
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/mpd-autostart.service" << 'UNIT_EOF'
[Unit]
Description=mpd autostart
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mpd --start
RemainAfterExit=yes

[Install]
WantedBy=default.target
UNIT_EOF
systemctl --user daemon-reload
systemctl --user enable mpd-autostart.service
EOF
ok "mpd will start automatically on VM boot"

step "Setting login banner"
ssh_cmd "$VM_IP" "$VM_USER" 'bash -se' <<'EOF'
set -e
sudo chmod -x /etc/update-motd.d/* 2>/dev/null || true
sudo cp "$HOME/Developer/mpd/assets/machine/motd" /etc/motd
EOF
ok "Login banner set"

step "VM bootstrap complete"
echo "    ${VM_USER}@${VM_IP} (${VM_NAME})"
