#!/bin/bash
# start.sh — start the current mpd VM (detected from the persistent route).
# Called by start.command.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

[ -x "$PRLCTL" ] || { echo "prlctl not found at $PRLCTL — Parallels Desktop Pro not installed?"; exit 1; }

octet=$(get_current_vm_octet)
if [ -z "$octet" ]; then
    octet=$(read_current_env_field "MPD_VM_IP" | awk -F. '{print $4}')
fi
if [ -z "$octet" ]; then
    echo "No mpd VM configured. Run setup.command first."
    exit 1
fi

vm_name="${VM_NAME_PREFIX}${octet}"
vm_ip="${BRIDGE_SUBNET}.${octet}"
vm_user=$(get_vm_ssh_user "$vm_name")

if ! vm_exists "$vm_name"; then
    echo "VM '${vm_name}' not found in Parallels. Run setup.command to create or reconfigure."
    exit 1
fi

# SSH liveness is the source of truth. `prlctl status` can drift from
# in-guest reality (panic, in-VM shutdown, etc.), so trust the
# connection probe before deciding to restart.
if ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no \
       "${vm_user}@${vm_ip}" true 2>/dev/null; then
    echo "${vm_name} is already reachable (${vm_ip})."
else
    state=$(get_vm_state "$vm_name")
    if [ "$state" = "running" ]; then
        echo "${vm_name} reports as running but is unreachable — recycling..."
        vm_force_stop "$vm_name" >/dev/null 2>&1 || true
        elapsed=0
        while [ "$elapsed" -lt 20 ]; do
            [ "$(get_vm_state "$vm_name")" = "stopped" ] && break
            sleep 1
            elapsed=$((elapsed + 1))
        done
    fi
    echo "Starting ${vm_name}..."
    vm_start "$vm_name" >/dev/null 2>&1 || true
    wait_for_ssh "$vm_ip" "$vm_user" 120 \
        || die "SSH not available after 120s. Open Parallels Desktop to inspect the VM."
    echo "${vm_name} started (${vm_ip})."
fi

# The persistent route to 10.163.0.0/24 is not preserved across host
# reboots unless the shared LaunchDaemon is installed; re-assert it
# (and refresh the resolver / CA if missing) cheaply. Skip CA fetch
# since the VM may still be settling.
bash "${SCRIPT_DIR}/configure-client.sh" \
    --vm-ip="$vm_ip" --vm-user="$vm_user" --skip-ca
