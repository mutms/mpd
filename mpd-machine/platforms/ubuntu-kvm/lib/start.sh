#!/bin/bash
# start.sh — start the current mpd VM (detected from the persistent route
# or ~/.mpd-machine/current.env). Called by the desktop launcher's
# connect.sh and by the entry shim ../start.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

octet=$(get_current_vm_octet)
if [ -z "$octet" ]; then
    octet=$(read_current_env_field "MPD_VM_IP" | awk -F. '{print $4}')
fi
if [ -z "$octet" ]; then
    echo "No mpd VM configured. Run setup.sh first."
    exit 1
fi

vm_name="${VM_NAME_PREFIX}${octet}"
vm_ip="${BRIDGE_SUBNET}.${octet}"
vm_user=$(get_vm_ssh_user "$vm_name")

if ! vm_exists "$vm_name"; then
    echo "VM '${vm_name}' not found in libvirt. Run setup.sh to create or reconfigure."
    exit 1
fi

# SSH liveness is the source of truth. virsh `running` can lag actual VM
# state (in-guest shutdown, kernel panic, etc.) so we never trust it alone.
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
            [ "$(get_vm_state "$vm_name")" = "shut off" ] && break
            sleep 1
            elapsed=$((elapsed + 1))
        done
    fi
    echo "Starting ${vm_name}..."
    vm_start "$vm_name" >/dev/null 2>&1 || true
    wait_for_ssh "$vm_ip" "$vm_user" 120 \
        || die "SSH not available after 120s. Open virt-manager to inspect or 'virsh console ${vm_name}'."
    echo "${vm_name} started (${vm_ip})."
fi

# Re-assert host route to the container subnet — `ip route` entries don't
# survive host reboots. The other host config (resolver drop-in, system
# trust, Firefox policies, NSS DB) is persistent and doesn't need re-applying
# here. Needs sudo only when the route's actually missing — silent on a
# warm restart of the VM in the same host session.
if route_needs_update "$vm_ip"; then
    echo
    echo "Re-asserting host route to ${CONTAINER_SUBNET_PREFIX} via ${vm_ip}"
    echo "(needs sudo — host reboots clear the kernel routing table):"
    echo
    if ! sudo ip route replace "$CONTAINER_SUBNET_PREFIX" via "$vm_ip"; then
        warn "could not add route — *.mpd.test from this host won't work until you run:"
        warn "  sudo ip route replace ${CONTAINER_SUBNET_PREFIX} via ${vm_ip}"
    fi
fi
