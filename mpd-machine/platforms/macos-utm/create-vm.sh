#!/bin/bash
# create-vm.sh — Create a Debian Trixie VM on UTM for mpd-machine.
#
# Uses the Debian cloud image — no manual installation required.
# Cloud-init configures the VM automatically on first boot:
#   - Creates user matching your Mac username with SSH key
#   - Grows root partition to fill the disk
#   - Installs all required packages to build mpd
#
# UTM QEMU backend (arm64).
#
# Prerequisites:
#   - Apple M1 or later processor
#   - UTM installed (App Store or direct download)
#   - SSH key at ~/.ssh/id_ed25519 (or id_rsa)
#
# Usage:
#   ./create-vm.sh              # prompts for the last IP octet (default 158)
#                               # → VM name 'mpd-machine-158', IP 192.168.64.158,
#                               #   in-VM hostname 'mpd-machine-158'.
#
# The script prompts for the last IP octet on the vmnet shared bridge. Pick a
# different octet to run multiple VMs side-by-side (e.g. .158 + .159) — each
# gets its own UTM display name, static IP, and in-VM hostname so shell
# prompts and PHPStorm sessions are unambiguous. mpd's internal "active
# machine" label stays 'mpd-machine' regardless of OS hostname.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Configuration ---
VM_MEMORY=12288     # MiB (12 GB) — can be changed later in UTM (stop VM > Edit > System)
VM_CPUS=4           # can be changed later in UTM (stop VM > Edit > System)
VM_DISK_SIZE_DEFAULT=200    # GB — prompted at runtime; cloud image is ~3 GB, resized to the chosen size before UTM imports it into the VM bundle
VM_OCTET_DEFAULT=158        # last octet of vmnet IP — prompted at runtime; drives VM name + IP + in-VM hostname
VM_GATEWAY="192.168.64.1"   # vmnet shared bridge gateway (fixed by macOS vmnet.framework)
VM_NAME=""                  # set after prompt: mpd-machine-${VM_OCTET}
VM_IP=""                    # set after prompt: 192.168.64.${VM_OCTET}
BASE_DIR="$(dirname "${SCRIPT_DIR}")"
TEMP_DIR="${SCRIPT_DIR}/temp"
UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"
MPD_REPO="https://github.com/mutms/mpd.git"

# Cloud image URL (tar.xz of raw disk — small download, resizable with dd)
CLOUD_BASE="https://cloud.debian.org/images/cloud/trixie/20260501-2465/"
CLOUD_ARCHIVE="debian-13-genericcloud-arm64-20260501-2465.tar.xz"

# --- Helper functions ---

die() { echo "Error: $*" >&2; exit 1; }

step() { echo "==> $*"; }

ok() { echo "  ✓ $*"; }

ssh_cmd() {
    local host="$1" user="$2"
    shift 2
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes "${user}@${host}" "$@"
}

# --- Prerequisites ---

mkdir -p "$TEMP_DIR"
rm -f "$TEMP_DIR/seed.iso"
rm -f "$TEMP_DIR/cidata/meta-data"
rm -f "$TEMP_DIR/cidata/network-config"
rm -f "$TEMP_DIR/cidata/user-data"

step "Checking prerequisites"

# UTM
if [ ! -d "/Applications/UTM.app" ]; then
    die "UTM is not installed. Get it from https://mac.getutm.app/ or the Mac App Store."
fi
ok "UTM installed"

# SSH key
SSH_KEY=""
for key in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
    if [ -f "$key" ]; then
        SSH_KEY="$key"
        break
    fi
done
if [ -z "$SSH_KEY" ]; then
    die "No SSH key found. Run: ssh-keygen -t ed25519"
fi
ok "SSH key: $SSH_KEY"

# --- Prompt for VM identity (last IP octet → name + IP + hostname) ---

VM_OCTET=""
while [ -z "$VM_OCTET" ]; do
    read -r -p "Last IP octet (192.168.64.NN, also used in VM name + hostname) [${VM_OCTET_DEFAULT}]: " VM_OCTET
    VM_OCTET="${VM_OCTET:-$VM_OCTET_DEFAULT}"
    if ! [[ "$VM_OCTET" =~ ^[0-9]+$ ]] || [ "$VM_OCTET" -lt 2 ] || [ "$VM_OCTET" -gt 254 ]; then
        echo "  Octet must be a whole number 2..254. Try again."
        VM_OCTET=""
    fi
done
VM_NAME="mpd-machine-${VM_OCTET}"
VM_IP="192.168.64.${VM_OCTET}"
ok "VM identity: name=${VM_NAME}, IP=${VM_IP}"

# Check VM doesn't already exist (utmctl status exits non-zero when the VM is
# missing; matches by exact name, unlike `utmctl list | grep` which substring-
# matches and would flag `mpd-machine-test-extra` when `mpd-machine-test` exists).
if "$UTMCTL" status "$VM_NAME" >/dev/null 2>&1; then
    die "VM '$VM_NAME' already exists in UTM. Delete it first or pick a different octet."
fi

# --- Prompt for disk size ---

VM_DISK_SIZE=""
while [ -z "$VM_DISK_SIZE" ]; do
    read -r -p "VM disk size in GB [${VM_DISK_SIZE_DEFAULT}]: " VM_DISK_SIZE
    VM_DISK_SIZE="${VM_DISK_SIZE:-$VM_DISK_SIZE_DEFAULT}"
    if ! [[ "$VM_DISK_SIZE" =~ ^[0-9]+$ ]] || [ "$VM_DISK_SIZE" -lt 8 ]; then
        echo "  Disk size must be a whole number of GB ≥ 8. Try again."
        VM_DISK_SIZE=""
    fi
done
ok "Disk size: ${VM_DISK_SIZE} GB"

# --- Download cloud image ---

step "Preparing Debian Trixie cloud image"

CACHED_ARCHIVE="${TEMP_DIR}/${CLOUD_ARCHIVE}"
if [ -f "$CACHED_ARCHIVE" ]; then
    ok "Using cached: $(basename "$CACHED_ARCHIVE")"
else
    echo "  Downloading ${CLOUD_ARCHIVE} (~200 MB)..."
    curl -L --progress-bar -o "$CACHED_ARCHIVE" "${CLOUD_BASE}/${CLOUD_ARCHIVE}"
    ok "Downloaded: ${CLOUD_ARCHIVE}"
fi

# Extract raw disk from tar.xz and resize to VM_DISK_SIZE
DISK_PATH="${TEMP_DIR}/${VM_NAME}.raw"
echo "  Extracting raw disk image..."
# Clear any leftover raw images from prior runs so the freshly-extracted file
# is unambiguous (the extracted name varies by Debian release).
find "$TEMP_DIR" -maxdepth 1 \( -name "*.raw" -o -name "disk.*" \) -delete 2>/dev/null || true
tar -xJf "$CACHED_ARCHIVE" -C "$TEMP_DIR"
RAW_FILE=$(find "$TEMP_DIR" -maxdepth 1 -name "*.raw" -print -quit)
if [ -z "$RAW_FILE" ]; then
    # Some archives use disk.raw
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

# --- Create cloud-init seed ISO ---

step "Creating cloud-init configuration"

SSH_PUB_KEY=$(cat "$SSH_KEY")
MAC_USER=$(whoami)

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
  - name: ${MAC_USER}
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
    gateway4: ${VM_GATEWAY}
    nameservers:
      addresses: [${VM_GATEWAY}]
EOF

# Create ISO with volume label "cidata" (required by cloud-init NoCloud datasource)
SEED_ISO="${TEMP_DIR}/seed.iso"
hdiutil makehybrid -o "$SEED_ISO" -iso -joliet -default-volume-name cidata "$CIDATA_DIR" >/dev/null 2>&1
ok "Cloud-init seed ISO created"

rm -rf "$CIDATA_DIR"
ok "Cloud-init temp files removed"

# --- Create UTM VM ---

step "Creating mpd-machine VM in UTM '${VM_NAME}'"

DISK_ABS="$DISK_PATH"
SEED_ABS="$SEED_ISO"

# QEMU backend, aarch64. The primary disk is imported into the VM bundle so
# the machine does not depend on TEMP_DIR. QEMU + SPICE gives us clipboard
# sync, dynamic display resize, and visible DHCP leases in UTM's GUI.
osascript <<APPLESCRIPT
tell application "UTM"
    set diskFile to POSIX file "${DISK_ABS}"
    set seedFile to POSIX file "${SEED_ABS}"
    make new virtual machine with properties { ¬
        backend:qemu, ¬
        configuration:{ ¬
            name:"${VM_NAME}", ¬
            architecture:"aarch64", ¬
            memory:${VM_MEMORY}, ¬
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

# --- Start the VM ---

step "Starting VM (cloud-init runs on first boot — takes 1-3 minutes)"

osascript <<APPLESCRIPT
tell application "UTM"
    set vm to virtual machine named "${VM_NAME}"
    start vm
end tell
APPLESCRIPT

ok "VM started"

# --- Wait for SSH (cloud-init must finish first) ---

# Wipe stale SSH host keys. All mpd targets sit on fixed IPs/names (see
# mpd/Mpd.swift §"Address layout"), so a fresh VM means every cached host key
# from the previous one is wrong — `ssh` and PHPStorm would otherwise abort
# with "REMOTE HOST IDENTIFICATION HAS CHANGED".
known_hosts_targets=(
    "${VM_IP}"                       "${VM_NAME}"
    fileaccess.service.mpd.test      10.163.0.5
    php.runtime.mpd.test             10.163.0.100
    node.runtime.mpd.test            10.163.0.101
    trixie.runtime.mpd.test          10.163.0.102
)
for host in "${known_hosts_targets[@]}"; do
    ssh-keygen -R "$host" >/dev/null 2>&1 || true
done

step "Waiting for SSH at ${VM_IP} (cloud-init is installing packages)"

VM_USER="$MAC_USER"
elapsed=0
timeout=300
while [ $elapsed -lt $timeout ]; do
    if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o BatchMode=yes \
           "${VM_USER}@${VM_IP}" true 2>/dev/null; then
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    if [ $((elapsed % 30)) -eq 0 ]; then
        echo "  Still waiting... (${elapsed}s / ${timeout}s)"
    fi
done

if [ $elapsed -ge $timeout ]; then
    die "SSH not available after ${timeout}s. Check the VM in UTM — cloud-init may still be running."
fi
ok "SSH ready (${VM_USER}@${VM_IP})"

# --- Wait for cloud-init to finish ---

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
        echo "  Still running... (${elapsed}s / ${timeout}s)"
    fi
done

if [ $elapsed -ge $timeout ]; then
    echo "  Warning: cloud-init may not have finished. Continuing anyway..."
fi
ok "Cloud-init complete"

# --- Verify root filesystem resize ---

step "Verifying root filesystem size"

ROOT_DEVICE=$(ssh_cmd "$VM_IP" "$VM_USER" "findmnt -n -o SOURCE /" 2>/dev/null || true)
ROOT_SIZE_GB=$(ssh_cmd "$VM_IP" "$VM_USER" "df -k / | awk 'NR==2 {printf \"%d\", int(\$2/1024/1024)}'" 2>/dev/null || true)

if [ -n "$ROOT_DEVICE" ] && [ -n "$ROOT_SIZE_GB" ]; then
    # Allow some overhead for partitioning/filesystem metadata.
    MIN_EXPECTED_GB=$((VM_DISK_SIZE - 5))
    if [ "$ROOT_SIZE_GB" -lt "$MIN_EXPECTED_GB" ]; then
        echo "  Warning: root filesystem looks smaller than expected (${ROOT_SIZE_GB}G, target ~${VM_DISK_SIZE}G)."
        echo "  Device: ${ROOT_DEVICE}"
        echo "  Check growpart/cloud-init logs inside the VM if needed."
    else
        ok "Root filesystem: ${ROOT_DEVICE} (${ROOT_SIZE_GB}G)"
    fi
else
    echo "  Warning: could not verify root filesystem size."
fi

# --- Clone mpd repository ---

step "Cloning mpd repository in VM"

ssh_cmd "$VM_IP" "$VM_USER" "export MPD_REPO=$(printf '%q' "$MPD_REPO"); bash -se" <<'EOF'
set -e

# cloud-init's package install can silently miss on flaky Debian mirrors —
# `boot-finished` gets written either way. Defensively ensure git is present
# before we try to clone; --retries lets a transient mirror error self-heal.
if ! command -v git >/dev/null 2>&1; then
    echo "  packages missing (cloud-init apt likely flaked) — installing now"
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
echo "  Repository cloned to $HOME/Developer/mpd"
EOF

ok "Repository ready"

# --- Platform identity (~/Developer/mpd/conf/platform.env) ---
# UTM-on-macOS knows everything statically: platform=macos-utm, client=macos,
# VM IP = the static IP we just assigned. Survives `mpd --uninstall`.

step "Writing platform identity to conf/platform.env"

ssh_cmd "$VM_IP" "$VM_USER" "export VM_IP=$(printf '%q' "$VM_IP"); bash -se" <<'EOF'
set -e
mkdir -p "$HOME/Developer/mpd/conf"
cat > "$HOME/Developer/mpd/conf/platform.env" <<PLATFORM_EOF
# mpd platform identity — written by macos-utm/create-vm.sh.
# Lives under conf/ so it survives \`mpd --uninstall\`.
MPD_PLATFORM=macos-utm
MPD_CLIENT_OS=macos
MPD_VM_IP=${VM_IP}
PLATFORM_EOF
chmod 0644 "$HOME/Developer/mpd/conf/platform.env"
echo "  Wrote $HOME/Developer/mpd/conf/platform.env"
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

elapsed=0
timeout=300
while [ $elapsed -lt $timeout ]; do
    if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o BatchMode=yes \
           "${VM_USER}@${VM_IP}" true 2>/dev/null; then
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done

if [ $elapsed -ge $timeout ]; then
    die "VM did not come back after detaching the cloud-init CD."
fi

ok "VM restarted"

# Install all necessary Debian packages

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
# Acquire::Retries lets transient Debian mirror errors self-heal.
sudo apt-get -o Acquire::Retries=3 update
sudo apt-get -o Acquire::Retries=3 install -y --no-install-recommends build-essential pkg-config make swiftlang

if ! command -v swift >/dev/null 2>&1; then
    echo "Swift install did not expose 'swift' on PATH" >&2
    exit 1
fi

EOF

ok "Required packages were installed"

# --- Build mpd binary and add it to path---

step "Building and installing mpd"

ssh_cmd "$VM_IP" "$VM_USER" 'bash -se' <<'EOF'
cd "$HOME/Developer/mpd"
make install
sudo ln -sf "$HOME/Developer/mpd/bin/mpd" /usr/local/bin/mpd
EOF

ok "mpd built and installed"

# --- Ensure ~/.local/bin on PATH for non-login shells (Claude Code, etc.) ---
# Debian's default ~/.profile already adds it for login shells; this covers
# `ssh user@host <command>` and other non-login interactive sessions.

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

# --- Run mpd --setup inside the VM ---
# Non-interactive on machine (passwordless sudo is a hard gate; no prompts),
# idempotent. If this fails, SSH in and re-run `mpd --setup`, or delete the
# VM and re-run create-vm.sh.

step "Running 'mpd --setup' (CA, podman network, services)"

ssh_cmd "$VM_IP" "$VM_USER" 'mpd --setup'

ok "mpd --setup complete"

# --- Auto-start on VM boot ---

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

# --- Login banner ---

step "Setting login banner"

ssh_cmd "$VM_IP" "$VM_USER" 'bash -se' <<'EOF'
set -e
sudo chmod -x /etc/update-motd.d/* 2>/dev/null || true
sudo cp "$HOME/Developer/mpd/assets/machine/motd" /etc/motd
EOF

ok "Login banner set"

# --- Show follow up instructions ---

cat <<EOF

VM bootstrap complete.

Next steps:
  sudo sh -c 'printf "%s %s\n" "${VM_IP}" "${VM_NAME}" >> /etc/hosts'
  ssh ${VM_USER}@${VM_IP}

EOF
