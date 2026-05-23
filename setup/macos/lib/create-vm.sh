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
#       --host-ca-pem=... --host-ca-key=...
#
# Memory, CPU count, and disk size are inherited from the Parallels
# template (`mpd-template`) — tune them on the template, not here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

# --- Args ---

VM_OCTET=""
VM_USER=""
SSH_KEY=""
ARG_HOST_CA_PEM=""
ARG_HOST_CA_KEY=""

for arg in "$@"; do
    case "$arg" in
        --octet=*)         VM_OCTET="${arg#*=}" ;;
        --user=*)          VM_USER="${arg#*=}" ;;
        --ssh-pub-key=*)   SSH_KEY="${arg#*=}" ;;
        --host-ca-pem=*)   ARG_HOST_CA_PEM="${arg#*=}" ;;
        --host-ca-key=*)   ARG_HOST_CA_KEY="${arg#*=}" ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

[ -n "$VM_OCTET" ]         || die "Missing --octet"
[ -n "$VM_USER" ]          || die "Missing --user"
[ -n "$SSH_KEY" ]          || die "Missing --ssh-pub-key"
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

step "Creating VM: name=${VM_NAME} ip=${VM_IP} user=${VM_USER} (memory/cpu/disk from template)"

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

step "Waiting for sshd to come up at ${DHCP_IP}"
wait_for_ssh_port "$DHCP_IP" 180 \
    || die "TCP/22 not reachable at ${DHCP_IP} within 180s."
ok "sshd listening at ${DHCP_IP}:22"

# --- Authorize the dev's SSH key via ssh-copy-id (one password prompt) ---
# Freshly-cloned VMs only carry the template-builder's key (or no key at
# all for this user). ssh-copy-id pushes our key with one interactive
# password — every subsequent ssh / scp can use BatchMode=yes. Idempotent
# on re-run: if the key is already there, ssh-copy-id no-ops without
# prompting.

step "Authorizing dev SSH key (interactive — you'll be prompted for the VM user's password)"
SSH_PUB_KEY_PATH="$SSH_KEY"
[ -f "$SSH_PUB_KEY_PATH" ] || die "SSH public key not found at ${SSH_PUB_KEY_PATH}."
ssh-copy-id \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -i "$SSH_PUB_KEY_PATH" \
    "${VM_USER}@${DHCP_IP}" \
    || die "ssh-copy-id failed. Check the VM user's password and that the user exists in the template."
ok "Dev SSH key authorized (BatchMode SSH should now work)"

# --- Bootstrap step 10: passwordless sudo (interactive root pw via ssh -t) ---
# `ssh -t` allocates a TTY so `su -c` inside bootstrap step 10 can prompt
# for the root password. One interactive prompt per fresh clone.

MPD_BRANCH="${MPD_BRANCH:-main}"
MPD_REPO_RAW="https://raw.githubusercontent.com/mutms/mpd/${MPD_BRANCH}"

step "Bootstrap 10: passwordless sudo (interactive — root password prompt)"
ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${VM_USER}@${DHCP_IP}" \
    "bash <(wget -qO- ${MPD_REPO_RAW}/bootstrap/10-passwordless-sudo.sh)" \
    || die "bootstrap/10 failed. Is the VM hostname mpd-template / mpd-sandbox / mpd-NNN?"
ok "Passwordless sudo configured"

# --- Bootstrap step 20: apt install git + git clone repo ---
step "Bootstrap 20: install git + clone mpd repo"
ssh_cmd "$DHCP_IP" "$VM_USER" \
    "MPD_BRANCH=$(printf '%q' "${MPD_BRANCH}") MPD_REPO=$(printf '%q' "${MPD_REPO}") \
     bash <(wget -qO- ${MPD_REPO_RAW}/bootstrap/20-git-clone.sh)" \
    || die "bootstrap/20 failed (git install + clone)."
ok "Repository cloned"

# --- Bootstrap step 30: hostname rename + static IP pin ---
# After this, SSH on the DHCP IP dies (the VM's interface flips to its
# new static IP). Wait for SSH on the new IP afterward.
step "Bootstrap 30: networking (hostname → ${VM_NAME}, static IP → ${VM_IP})"
ssh_cmd "$DHCP_IP" "$VM_USER" \
    "bash /opt/mpd/bootstrap/30-networking.sh $(printf '%q' "$VM_OCTET")" \
    || warn "bootstrap/30 ssh ended (expected — IP just changed)"

clear_known_hosts
for h in "$DHCP_IP" "$VM_IP" "$VM_NAME"; do
    ssh-keygen -R "$h" >/dev/null 2>&1 || true
done
step "Waiting for sshd at new static IP ${VM_IP}"
wait_for_ssh_port "$VM_IP" 180 \
    || die "VM did not come back at ${VM_IP} within 180s."
ok "sshd listening at ${VM_IP}:22"

# --- Bootstrap steps 40 + 50 + 60: apt install set, mpd build, optional WG ---
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

# --- Swap (Parallels-specific — 4 GB swap if none present) ---
# Not handled by bootstrap: it's per-hypervisor policy (sandbox VMs let
# the user manage swap, managed VMs in Parallels Shared get 4 GB).

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

# --- Upload host CA into VM so mpd --setup reuses it ---

step "Uploading host CA into VM"
ssh_cmd "$VM_IP" "$VM_USER" \
    "mkdir -p /var/lib/mpd/conf/caroot && chmod 700 /var/lib/mpd/conf/caroot"
scp -q -o StrictHostKeyChecking=no -o BatchMode=yes \
    "$ARG_HOST_CA_PEM" "$ARG_HOST_CA_KEY" \
    "${VM_USER}@${VM_IP}:/var/lib/mpd/conf/caroot/"
ssh_cmd "$VM_IP" "$VM_USER" "chmod 600 /var/lib/mpd/conf/caroot/rootCA*.pem"
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
sudo cp /opt/mpd/assets/machine/motd /etc/motd
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
