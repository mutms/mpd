#!/bin/bash
# start.sh — start the current mpd VM (detected from the persistent route).
# Called by start.command.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

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
    echo "VM '${vm_name}' not found in UTM. Run setup.command to create or reconfigure."
    exit 1
fi

state=$(get_vm_state "$vm_name")
if [ "$state" = "started" ]; then
    echo "${vm_name} is already running (${vm_ip})."
else
    echo "Starting ${vm_name} ..."
    vm_start "$vm_name"
    wait_for_ssh "$vm_ip" "$vm_user" 120 \
        || die "SSH not available after 120s. Open UTM to inspect the VM."
    echo "Started. SSH: ssh ${vm_user}@${vm_ip}"
fi

# The persistent route to 10.163.0.0/24 is not preserved across host
# reboots; re-assert it (and refresh the resolver / CA if missing) cheaply.
# Skip CA fetch since the VM may still be settling and SSH key auth was
# already used by wait_for_ssh.
bash "${SCRIPT_DIR}/configure-client.sh" \
    --vm-ip="$vm_ip" --vm-user="$vm_user" --skip-ca
