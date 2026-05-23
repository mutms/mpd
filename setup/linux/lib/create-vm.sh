#!/bin/bash
# create-vm.sh — Create a single Debian Trixie VM via libvirt for mpd-vm.
#
# Called by lib/setup.sh after the user has selected octet/user/memory/disk.
# Non-interactive (no prompts). Does not configure host networking — that's
# in lib/configure-client.sh and the host-side privileged block in setup.sh.
#
# Usage:
#   bash lib/create-vm.sh \
#       --octet=158 --user=skodak \
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
[ -n "$ARG_HOST_CA_PEM" ]  || die "Missing --host-ca-pem"
[ -n "$ARG_HOST_CA_KEY" ]  || die "Missing --host-ca-key"
[ -f "$SSH_KEY" ]          || die "SSH public key not found: $SSH_KEY"
[ -f "$ARG_HOST_CA_PEM" ]  || die "Host CA cert not found: $ARG_HOST_CA_PEM"
[ -f "$ARG_HOST_CA_KEY" ]  || die "Host CA key not found: $ARG_HOST_CA_KEY"

VM_NAME="${VM_NAME_PREFIX}${VM_OCTET}"
VM_IP="${BRIDGE_SUBNET}.${VM_OCTET}"
VM_MEMORY_MIB=$((VM_MEMORY_GB * 1024))
VM_CPUS=4

# Deterministic MAC: 52:54:00 (libvirt OUI) + 00:00 + octet (hex).
# Same OUI libvirt picks for `default` network, doesn't collide with the
# bridge gateway.
VM_MAC=$(printf '52:54:00:00:00:%02x' "$VM_OCTET")

POOL_NAME="$LIBVIRT_POOL_NAME"
POOL_DIR="$LIBVIRT_POOL_DIR"
TEMP_DIR="${SCRIPT_DIR}/temp"
mkdir -p "$TEMP_DIR"
# Preflight has already created LIBVIRT_POOL_PARENT (root-owned parent
# + user-owned subdir at /var/lib/mpd-virt/$USER); the pool's `disks/`
# subdir is created by `virsh pool-build` further down.

step "Creating VM: name=${VM_NAME} ip=${VM_IP} user=${VM_USER} memory=${VM_MEMORY_GB}GB disk=${VM_DISK_SIZE}GB mac=${VM_MAC}"

if vm_exists "$VM_NAME"; then
    die "VM '$VM_NAME' already exists in libvirt. Delete it first or pick a different octet."
fi

# --- Storage pool ---
# User-owned dir pool keeps disks accessible without sudo on the host;
# libvirtd's apparmor profile auto-allows libvirt-managed pool paths.

step "Ensuring libvirt storage pool '${POOL_NAME}' at ${POOL_DIR}"

# Pool target lives under /var/lib/mpd-virt/$USER/disks. The user-owned
# parent ($LIBVIRT_POOL_PARENT) was created by the preflight sudo recipe.
# We mkdir the `disks/` subdir ourselves rather than via `virsh pool-build`
# — libvirtd would execute pool-build as root, leaving the dir owned by
# root, and qemu-img convert later would fail with "Permission denied".
# libvirt-qemu still gets to read/write inside; apparmor permits any
# libvirt-managed pool path, and dynamic_ownership chowns disks to
# libvirt-qemu when VMs start.
mkdir -p "$POOL_DIR"

if ! virsh -c "$LIBVIRT_URI" pool-info "$POOL_NAME" >/dev/null 2>&1; then
    virsh -c "$LIBVIRT_URI" pool-define-as "$POOL_NAME" dir --target "$POOL_DIR" >/dev/null
    virsh -c "$LIBVIRT_URI" pool-start "$POOL_NAME" >/dev/null
    virsh -c "$LIBVIRT_URI" pool-autostart "$POOL_NAME" >/dev/null
    ok "pool created and started"
else
    state=$(virsh -c "$LIBVIRT_URI" pool-info "$POOL_NAME" 2>/dev/null \
        | awk -F: '/^State:/ { sub(/^[[:space:]]*/, "", $2); print $2 }')
    if [ "$state" != "running" ]; then
        virsh -c "$LIBVIRT_URI" pool-start "$POOL_NAME" >/dev/null
    fi
    ok "pool already exists"
fi

DISK_PATH="${POOL_DIR}/${VM_NAME}.qcow2"
SEED_ISO="${POOL_DIR}/${VM_NAME}-seed.iso"

# --- Download cloud image ---

step "Preparing Debian Trixie cloud image"

CACHED_ARCHIVE="${TEMP_DIR}/${CLOUD_ARCHIVE}"
if [ -f "$CACHED_ARCHIVE" ]; then
    ok "Using cached: $(basename "$CACHED_ARCHIVE")"
else
    echo "    Downloading ${CLOUD_ARCHIVE} (~250 MB)..."
    curl -L --progress-bar -o "$CACHED_ARCHIVE" "${CLOUD_BASE}/${CLOUD_ARCHIVE}"
    ok "Downloaded: ${CLOUD_ARCHIVE}"
fi

# --- Extract raw + convert+resize to qcow2 in the pool ---

step "Converting raw image to qcow2 in pool (${VM_DISK_SIZE}G sparse)"

# Clear any leftover raw images from prior runs so the freshly-extracted file
# is unambiguous (the extracted name varies by Debian release).
find "$TEMP_DIR" -maxdepth 1 \( -name "*.raw" -o -name "disk.*" \) -delete 2>/dev/null || true
tar -xJf "$CACHED_ARCHIVE" -C "$TEMP_DIR"
RAW_FILE=$(find "$TEMP_DIR" -maxdepth 1 -name "*.raw" -print -quit)
if [ -z "$RAW_FILE" ]; then
    RAW_FILE=$(find "$TEMP_DIR" -maxdepth 1 -name "disk.*" -print -quit)
fi
[ -z "$RAW_FILE" ] && die "Could not find raw disk image in archive"

# Reject too-small target sizes upfront.
RAW_BYTES=$(stat -c %s "$RAW_FILE")
TARGET_BYTES=$((VM_DISK_SIZE * 1024 * 1024 * 1024))
if [ "$TARGET_BYTES" -lt "$RAW_BYTES" ]; then
    die "Requested disk size ${VM_DISK_SIZE}G is smaller than the cloud image ($((RAW_BYTES / 1024 / 1024 / 1024))G). Pick a larger size."
fi

qemu-img convert -O qcow2 -o lazy_refcounts=on "$RAW_FILE" "$DISK_PATH"
qemu-img resize "$DISK_PATH" "${VM_DISK_SIZE}G" >/dev/null
rm -f "$RAW_FILE"
ok "qcow2 ready at ${DISK_PATH}"

# --- Cloud-init seed ISO ---

step "Building cloud-init seed ISO"

SSH_PUB_KEY=$(cat "$SSH_KEY")
CIDATA_DIR="${TEMP_DIR}/cidata"
rm -rf "$CIDATA_DIR"
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
  - path: /var/lib/mpd/conf/platform.env
    owner: ${VM_USER}:${VM_USER}
    permissions: '0644'
    defer: true
    content: |
      # mpd platform identity — written by cloud-init.
      # Bootstrap/30-networking.sh is skipped on cloud-init flows
      # (cloud-init owns hostname + netplan), so platform.env is
      # written here so the in-VM mpd binary can read its identity.
      MPD_PLATFORM=managed
      MPD_VM_IP=${VM_IP}
      MPD_VM_ID=$(printf '%03d' "${VM_OCTET}")

runcmd:
  - systemctl enable --now ssh
  - sysctl --load=/etc/sysctl.d/99-mpd-disable-ipv6.conf
EOF

# netplan via cloud-init network-config v2. Match by virtio_net driver so
# we don't have to hard-code an interface name (libvirt's interface naming
# can vary across machine types).
cat > "${CIDATA_DIR}/network-config" <<EOF
version: 2
ethernets:
  primary:
    match:
      driver: virtio_net
    addresses: [${VM_IP}/24]
    gateway4: ${BRIDGE_GATEWAY}
    nameservers:
      addresses: [${BRIDGE_GATEWAY}]
EOF

genisoimage -output "$SEED_ISO" -volid cidata -joliet -rock "$CIDATA_DIR" >/dev/null 2>&1
rm -rf "$CIDATA_DIR"
ok "seed ISO at ${SEED_ISO}"

# Refresh the pool so libvirt sees both files as managed volumes.
virsh -c "$LIBVIRT_URI" pool-refresh "$POOL_NAME" >/dev/null

# --- Define VM ---

step "Defining VM in libvirt"

VM_XML="${TEMP_DIR}/${VM_NAME}.xml"
cat > "$VM_XML" <<EOF
<domain type='kvm'>
  <name>${VM_NAME}</name>
  <metadata>
    <mpd xmlns='https://github.com/mutms/mpd'>
      <octet>${VM_OCTET}</octet>
      <user>${VM_USER}</user>
      <ip>${VM_IP}</ip>
    </mpd>
  </metadata>
  <memory unit='MiB'>${VM_MEMORY_MIB}</memory>
  <currentMemory unit='MiB'>${VM_MEMORY_MIB}</currentMemory>
  <vcpu placement='static'>${VM_CPUS}</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
    <boot dev='cdrom'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <vmport state='off'/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='on'/>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' discard='unmap'/>
      <source file='${DISK_PATH}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='${SEED_ISO}'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <mac address='${VM_MAC}'/>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'><target type='isa-serial' port='0'/></serial>
    <console type='pty'><target type='serial' port='0'/></console>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <video>
      <model type='virtio' heads='1'/>
    </video>
    <graphics type='spice' autoport='yes'>
      <listen type='address'/>
    </graphics>
    <memballoon model='virtio'>
      <stats period='10'/>
    </memballoon>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>
  </devices>
</domain>
EOF

virsh -c "$LIBVIRT_URI" define "$VM_XML" >/dev/null
rm -f "$VM_XML"
ok "VM defined"

# --- Start VM ---

step "Starting VM (cloud-init runs on first boot — takes 1-3 minutes)"

vm_start "$VM_NAME"

# Strip cached host keys for the IPs/names this VM will own.
clear_known_hosts
for h in "${VM_IP}" "${VM_NAME}"; do
    ssh-keygen -R "$h" >/dev/null 2>&1 || true
done

step "Waiting for SSH at ${VM_IP} (first boot — user creation, disk grow)"
wait_for_ssh "$VM_IP" "$VM_USER" 300 \
    || die "SSH not available after 300s. Check 'virsh console ${VM_NAME}' or virt-manager for boot progress."
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

# --- Verify root filesystem grew ---

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

# --- Bootstrap step 20: clone mpd repo ---
# (Cloud-init already handled step 10's job: passwordless sudo, SSH key,
# hostname, static IP, IPv6 disable. We skip bootstrap/30 entirely on
# cloud-init flows — it's NetworkManager-only, while cloud-init Debian
# uses systemd-networkd. platform.env was written via write_files above.)

MPD_BRANCH="${MPD_BRANCH:-main}"
MPD_REPO_RAW="https://raw.githubusercontent.com/mutms/mpd/${MPD_BRANCH}"

step "Bootstrap 20: install git + clone mpd repo"
ssh_cmd "$VM_IP" "$VM_USER" \
    "MPD_BRANCH=$(printf '%q' "${MPD_BRANCH}") MPD_REPO=$(printf '%q' "${MPD_REPO}") \
     bash <(wget -qO- ${MPD_REPO_RAW}/bootstrap/20-git-clone.sh)" \
    || die "bootstrap/20 failed (git install + clone)."
ok "Repository cloned"

# --- Detach cloud-init CD ---

step "Detaching cloud-init CD"

ssh_cmd "$VM_IP" "$VM_USER" "sudo shutdown -h now" >/dev/null 2>&1 || true
elapsed=0
while [ $elapsed -lt 120 ]; do
    [ "$(get_vm_state "$VM_NAME")" = "shut off" ] && break
    sleep 1
    elapsed=$((elapsed + 1))
done
if [ "$(get_vm_state "$VM_NAME")" != "shut off" ]; then
    warn "VM didn't power off cleanly within 120s — forcing"
    vm_force_stop "$VM_NAME" 2>/dev/null || true
fi

# Eject the seed CD via virsh change-media.
virsh -c "$LIBVIRT_URI" change-media "$VM_NAME" sda --eject --config 2>/dev/null \
    || warn "Could not eject seed CDROM via virsh; VM may still try to attach it on next boot"

rm -f "$SEED_ISO"
virsh -c "$LIBVIRT_URI" pool-refresh "$POOL_NAME" >/dev/null
ok "Seed ISO detached and removed"

step "Restarting VM without cloud-init CD"
vm_start "$VM_NAME"
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

# --- Bootstrap steps 40 + 50 + 60: apt install set, mpd build, optional WG ---
# Step 30 (networking) is skipped on cloud-init flows — cloud-init owns
# hostname + netplan on this VM, and bootstrap/30 is NetworkManager-only.

step "Bootstrap 40: apt install package set"
ssh_cmd "$VM_IP" "$VM_USER" \
    "bash /opt/mpd/bootstrap/40-install-software.sh" \
    || die "bootstrap/40 failed (apt install)."
ok "Packages installed"

step "Bootstrap 50: build mpd binary"
ssh_cmd "$VM_IP" "$VM_USER" \
    "bash /opt/mpd/bootstrap/50-build.sh" \
    || die "bootstrap/50 failed (make install)."
ok "mpd binary built"

step "Bootstrap 60: WireGuard (no-op when conf absent)"
ssh_cmd "$VM_IP" "$VM_USER" \
    "bash /opt/mpd/bootstrap/60-wireguard.sh" \
    || die "bootstrap/60 failed."
ok "Bootstrap complete"

step "Uploading host CA into VM (mpd will reuse it)"
ssh_cmd "$VM_IP" "$VM_USER" \
    "mkdir -p /var/lib/mpd/conf/caroot && chmod 700 /var/lib/mpd/conf/caroot"
scp -q -o StrictHostKeyChecking=no -o BatchMode=yes \
    "$ARG_HOST_CA_PEM" "$ARG_HOST_CA_KEY" \
    "${VM_USER}@${VM_IP}:/var/lib/mpd/conf/caroot/"
ssh_cmd "$VM_IP" "$VM_USER" "chmod 600 /var/lib/mpd/conf/caroot/rootCA*.pem"
ok "Host CA uploaded"

step "Running 'mpd --setup' (CA, podman network, services)"
ssh_cmd "$VM_IP" "$VM_USER" 'mpd --setup'
ok "mpd --setup complete"

step "VM bootstrap complete"
echo "    ${VM_USER}@${VM_IP} (${VM_NAME})"
