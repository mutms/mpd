#!/bin/bash
# doctor.sh — list all mpd-tracked VMs, show their state + whether the
# host route currently points at them, and (only when exactly one is
# running) verify / re-apply host networking + CA trust.
#
# Output shape:
#   Tracked mpd VMs (3):
#       mpd-machine-155        running    configured  ip=10.211.55.155
#       moodle-experiment      stopped               ip=10.211.55.156
#       mpd-machine-200        suspended             ip=10.211.55.200
#
#   …and then either a "fix it up" pass or a warning, depending on how
#   many are currently running.
#
# Multiple-runner case: doctor refuses to mutate host state. Two
# mpd-tracked VMs running at the same time can't both own the static
# Parallels Shared IP — even if today's route happens to match one of
# them, the other is partially live and will collide on the next ARP
# refresh. The user suspends all but one (Parallels: Cmd+P, super
# cheap) and re-runs doctor.
#
# Zero-runner case: nothing to fix; doctor reports and exits.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

[ -x "$PRLCTL" ] \
    || die "prlctl not found at $PRLCTL — Parallels Desktop Pro not installed?"

# --- Collect tracked VMs --------------------------------------------------

declare -a vm_uuids vm_names vm_states vm_ips
while IFS=$'\t' read -r u n s; do
    [ -z "$u" ] && continue
    vm_uuids+=("$u")
    vm_names+=("$n")
    vm_states+=("$s")
    vm_ips+=("$(get_vm_ip_by_uuid "$u")")
done < <(get_mpd_vms)

if [ ${#vm_uuids[@]} -eq 0 ]; then
    die "No mpd VMs tracked. Run setup.command first."
fi

# --- Report -------------------------------------------------------------
# The current persistent route's gateway tells us which VM IP the host
# is configured to talk to right now. We compare each running VM's IP
# against it for the "configured" tag.

route_gw=$(get_current_vm_route_ip)

step "Tracked mpd VMs (${#vm_uuids[@]})"
running_indices=()
configured_indices=()
for i in "${!vm_uuids[@]}"; do
    name="${vm_names[$i]}"
    state="${vm_states[$i]}"
    ip="${vm_ips[$i]}"
    tag=""
    if [ "$state" = "running" ]; then
        running_indices+=("$i")
        if [ -n "$route_gw" ] && [ "$route_gw" = "$ip" ]; then
            tag="configured"
            configured_indices+=("$i")
        else
            tag="NOT configured"
        fi
    fi
    printf '    %-24s %-10s %-15s ip=%s\n' "$name" "$state" "$tag" "${ip:-?}"
done

# --- Branch on running count --------------------------------------------

echo
case ${#running_indices[@]} in
    0)
        warn "No mpd VMs are running. Start one in Parallels and re-run doctor."
        exit 0
        ;;
    1)
        : # fall through to the fix-it pass below
        ;;
    *)
        warn "Multiple mpd VMs are running (${#running_indices[@]}). They all sit on the same"
        warn "Parallels Shared subnet and will collide on the static IP regardless of"
        warn "which one the host route currently points at."
        warn "Suspend all but one (Parallels: Cmd+P) and re-run doctor."
        exit 1
        ;;
esac

# --- Exactly one running → verify + apply host config -------------------

idx=${running_indices[0]}
vm_uuid="${vm_uuids[$idx]}"
vm_name="${vm_names[$idx]}"
vm_ip="${vm_ips[$idx]}"
vm_user=$(get_vm_ssh_user_by_uuid "$vm_uuid")

# If the running VM isn't what current.env points at (e.g. the user
# started a different mpd VM in Parallels), refresh current.env + the
# SSH config alias so the desktop shortcut and `ssh <name>` follow.
current_uuid=$(read_current_env_field "MPD_VM_UUID")
if [ "$current_uuid" != "$vm_uuid" ]; then
    step "Updating current.env + SSH alias to point at the running VM"
    set_mpd_ssh_config    "$vm_name" "$vm_ip" "$vm_user"
    write_mpd_current_env "$vm_uuid" "$vm_name" "$vm_ip" "$vm_user"
fi

step "Verifying host configuration for ${vm_name} (${vm_ip})"
bash "${SCRIPT_DIR}/configure-client.sh" \
    --vm-ip="$vm_ip" --vm-user="$vm_user"

echo
echo "    Open https://mpd.test/ to verify. Re-run setup.command if anything"
echo "    bigger is wrong; doctor only touches host networking + CA trust."
