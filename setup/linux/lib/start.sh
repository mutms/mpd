#!/bin/bash
# start.sh — start the current mpd VM. Detects current VM from the
# persistent route or ~/.mpd-virt/current.env.
#
# Order is intentional: if the route is missing (host reboot, link flap),
# ask for sudo BEFORE waiting on the VM to come up — the user enters
# their password once and can walk away. If the route is already in
# place, give the VM a quick 10s grace window in case it's mid-resume,
# then fall through to a full vm_start + wait_for_ssh if still down.

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

ssh_probe() {
    ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no \
        "${vm_user}@${vm_ip}" true 2>/dev/null
}

# --- Step 1: quick SSH probe ---

if ssh_probe; then
    echo "${vm_name} is already reachable (${vm_ip})."
    exit 0
fi

# --- Step 2: announce the action, then handle route + VM start ---

echo "Starting ${vm_name}..."

if route_needs_update "$vm_ip"; then
    # Route missing — get sudo upfront so the user doesn't have to come
    # back to enter a password after the VM is already up.
    echo
    echo "(Host route to ${CONTAINER_SUBNET_PREFIX} is missing — getting sudo"
    echo " upfront so you can walk away while the VM boots.)"
    cmds=("sudo ip route replace ${CONTAINER_SUBNET_PREFIX} via ${vm_ip}")
    print_sudo_recipe "${cmds[@]}"

    if route_needs_update "$vm_ip"; then
        sudo -v || die "sudo authentication failed."
        apply_route "$vm_ip"
        sudo -k 2>/dev/null || true
        ok "route added: ${CONTAINER_SUBNET_PREFIX} -> ${vm_ip}"
    else
        ok "route added (you ran the recipe manually)"
    fi
else
    # Route already in place. The VM is probably mid-resume from a
    # managedsave; 10s grace before we do anything heavy.
    echo "(Route to ${CONTAINER_SUBNET_PREFIX} already in place — giving the VM 10s to come up.)"
    sleep 10
    if ssh_probe; then
        echo "${vm_name} is now reachable (${vm_ip})."
        exit 0
    fi
fi

# --- Step 3: actually start the VM (or recycle if stuck) ---

state=$(get_vm_state "$vm_name")
if [ "$state" = "running" ]; then
    # libvirt thinks it's running but SSH isn't responding. Force a clean
    # restart so we don't sit waiting on a dead in-guest process.
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
