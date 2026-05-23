#!/bin/bash
# uninstall.sh — undo host networking + trust, then (per-VM y/N) delete
# mpd VMs. Mirrors macos/lib/uninstall.sh's structure.
#
# Order is deliberate: host cleanup runs first, VM deletion is the last
# step. Ctrl-C during the per-VM prompts therefore leaves the host fully
# cleaned up with the remaining VMs intact — those can still be reached
# by re-running setup.sh (which restores host networking).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

# --- Discover VMs ---

vms=()
while IFS=$'\t' read -r name state; do
    [ -n "$name" ] && vms+=("${name}|${state}")
done < <(get_mpd_vms)

# --- Detect host cleanup targets (read-only) ---
# Globals: remove_route, remove_resolver, remove_systrust, remove_firefox,
# remove_nssdb. Re-callable so we can re-detect after the dev runs the
# recipe in another terminal.

remove_route=0
remove_resolver=0
remove_systrust=0
remove_firefox=0
remove_nssdb=0

detect_host_targets() {
    remove_route=0
    remove_resolver=0
    remove_systrust=0
    remove_firefox=0
    remove_nssdb=0

    if [ -n "$(ip route show "$CONTAINER_SUBNET_PREFIX" 2>/dev/null)" ]; then
        remove_route=1
    fi

    [ -f "$RESOLVED_DROPIN_FILE" ] && remove_resolver=1
    [ -f "$SYSTEM_TRUST_CERT" ]   && remove_systrust=1
    { [ -f "$FIREFOX_POLICIES_FILE" ] || [ -f "$FIREFOX_POLICIES_CERT" ]; } \
        && remove_firefox=1

    if command -v certutil >/dev/null 2>&1 \
       && [ -f "${NSSDB_DIR}/cert9.db" ] \
       && certutil -d "sql:${NSSDB_DIR}" -L -n "$NSSDB_CERT_NICKNAME" >/dev/null 2>&1; then
        remove_nssdb=1
    fi
}

detect_host_targets

# --- Detect pool/disks (informational for the banner) ---

pool_defined=0
pool_dir_present=0
command -v virsh >/dev/null 2>&1 \
    && virsh -c "$LIBVIRT_URI" pool-info "$LIBVIRT_POOL_NAME" >/dev/null 2>&1 \
    && pool_defined=1
[ -d "$LIBVIRT_POOL_PARENT" ] && pool_dir_present=1

# --- Banner + confirmation ---

echo
echo "This will undo mpd-vm setup on this host."
echo
echo "Host networking and trust to remove:"
[ "$remove_route" = 1 ]    && echo "    - persistent route to ${CONTAINER_SUBNET_PREFIX}"
[ "$remove_resolver" = 1 ] && echo "    - ${RESOLVED_DROPIN_FILE}"
[ "$remove_systrust" = 1 ] && echo "    - ${SYSTEM_TRUST_CERT} (system trust)"
[ "$remove_firefox" = 1 ]  && echo "    - Firefox policy + cert in ${FIREFOX_POLICIES_DIR}/"
[ "$remove_nssdb" = 1 ]    && echo "    - mpd CA cert in ~/.pki/nssdb (Chromium)"
echo "    - ${STATE_DIR}/"
echo "    - 'Host mpd-vm' block from ~/.ssh/config"
echo "    - desktop launcher (.desktop files in ~/.local/share/applications/ and ~/Desktop/)"
echo

if [ "$pool_defined" = 1 ]; then
    echo "If you delete every VM in the per-VM prompts at the end, the libvirt"
    echo "storage pool '${LIBVIRT_POOL_NAME}' will also be undefined. The user-owned"
    echo "directory ${LIBVIRT_POOL_PARENT}/ is left in place either way — rm -rf"
    echo "it yourself if you want a full reset."
    echo
fi

if [ ${#vms[@]} -eq 0 ]; then
    echo "Existing mpd VMs: (none)"
else
    echo "Existing mpd VMs (you'll be asked about each individually at the end):"
    for entry in "${vms[@]}"; do
        echo "    ${entry%|*}  (${entry#*|})"
    done
    echo
    echo "If you keep any VM, host networking is still removed; re-run"
    echo "setup.sh later with that VM's number to restore it."
fi
echo

read -r -p "Type YES to proceed: " confirm
if [ "$confirm" != "YES" ]; then
    echo "Aborted."
    exit 0
fi

trap 'sudo -k 2>/dev/null || true' EXIT

# --- NSS DB cleanup (user-level, no sudo) ---

if [ "$remove_nssdb" = 1 ]; then
    if certutil -d "sql:${NSSDB_DIR}" -D -n "$NSSDB_CERT_NICKNAME" 2>/dev/null; then
        echo "mpd CA removed from ~/.pki/nssdb."
    else
        warn "could not remove mpd CA from ~/.pki/nssdb — try certutil manually."
    fi
    remove_nssdb=0
fi

# --- Privileged host cleanup (sudo recipe affordance) ---

if [ "$remove_route" = 1 ] || [ "$remove_resolver" = 1 ] \
   || [ "$remove_systrust" = 1 ] || [ "$remove_firefox" = 1 ]; then
    cmds=()
    if [ "$remove_route" = 1 ]; then
        cmds+=("sudo ip route del ${CONTAINER_SUBNET_PREFIX}")
    fi
    if [ "$remove_resolver" = 1 ]; then
        cmds+=("sudo rm -f ${RESOLVED_DROPIN_FILE}")
        cmds+=("sudo systemctl restart systemd-resolved")
    fi
    if [ "$remove_systrust" = 1 ]; then
        cmds+=("sudo rm -f ${SYSTEM_TRUST_CERT}")
        cmds+=("sudo update-ca-certificates")
    fi
    if [ "$remove_firefox" = 1 ]; then
        cmds+=("sudo rm -f ${FIREFOX_POLICIES_FILE} ${FIREFOX_POLICIES_CERT}")
        cmds+=("sudo rmdir ${FIREFOX_POLICIES_DIR} 2>/dev/null || true")
        cmds+=("sudo rmdir /etc/firefox 2>/dev/null || true")
    fi

    print_sudo_recipe "${cmds[@]}"

    detect_host_targets

    if [ "$remove_route" = 0 ] && [ "$remove_resolver" = 0 ] \
       && [ "$remove_systrust" = 0 ] && [ "$remove_firefox" = 0 ]; then
        ok "host cleanup already complete (you ran the recipe manually)"
    else
        sudo -v || die "sudo authentication failed."
        if [ "$remove_route" = 1 ]; then
            sudo ip route del "$CONTAINER_SUBNET_PREFIX" 2>/dev/null || true
            echo "Container subnet route removed."
        fi
        if [ "$remove_resolver" = 1 ]; then
            sudo rm -f "$RESOLVED_DROPIN_FILE"
            sudo systemctl restart systemd-resolved 2>/dev/null || true
            echo "${RESOLVED_DROPIN_FILE} removed."
        fi
        if [ "$remove_systrust" = 1 ]; then
            sudo rm -f "$SYSTEM_TRUST_CERT"
            sudo update-ca-certificates >/dev/null 2>&1 || true
            echo "${SYSTEM_TRUST_CERT} removed."
        fi
        if [ "$remove_firefox" = 1 ]; then
            sudo rm -f "$FIREFOX_POLICIES_FILE" "$FIREFOX_POLICIES_CERT"
            sudo rmdir "$FIREFOX_POLICIES_DIR" 2>/dev/null || true
            sudo rmdir /etc/firefox 2>/dev/null || true
            echo "Firefox policies + cert removed."
        fi
        sudo -k 2>/dev/null || true
    fi
else
    ok "no host networking or trust changes needed (already clean)"
fi

# --- Local file cleanup (no sudo) ---

if [ -d "$STATE_DIR" ]; then
    rm -rf "$STATE_DIR"
    echo "${STATE_DIR}/ removed."
fi

remove_mpd_ssh_config
echo "SSH config block removed."

remove_desktop_shortcut
echo "Desktop launcher removed."

# --- Per-VM deletion (last step — Ctrl-C here is safe) ---
# kept VMs later. Pool teardown after the loop, only if every VM was deleted.

kept_count=0
if [ ${#vms[@]} -gt 0 ]; then
    echo
    echo "VM deletion (default keeps each VM — press Enter or 'n' to skip):"
    for entry in "${vms[@]}"; do
        name="${entry%|*}"
        state="${entry#*|}"
        read -r -p "    Delete ${name} (${state})? [y/N]: " ans
        if [[ "$ans" =~ ^[Yy] ]]; then
            if [ "$state" = "running" ] || [ "$state" = "paused" ]; then
                echo "    Stopping ${name} ..."
                vm_force_stop "$name" 2>/dev/null || true
                elapsed=0
                while [ "$elapsed" -lt 20 ]; do
                    [ "$(get_vm_state "$name")" = "shut off" ] && break
                    sleep 1
                    elapsed=$((elapsed + 1))
                done
            fi
            echo "    Deleting ${name} ..."
            vm_delete "$name" 2>/dev/null \
                || warn "Could not delete ${name} via virsh — remove it manually with virt-manager / virsh undefine."
        else
            echo "    Kept ${name}."
            kept_count=$((kept_count + 1))
        fi
    done
fi

# --- Pool teardown (only if no kept VMs) ---
# We undefine the libvirt pool (no sudo, libvirt-group user can do this)
# but leave the user-owned ${LIBVIRT_POOL_PARENT}/ directory in place —
# it's an empty dir, harmless, and avoids one more sudo prompt at the end
# of an otherwise-finished teardown. `rm -rf ${LIBVIRT_POOL_PARENT}` if
# you want full cleanup.

if [ "$kept_count" = 0 ] && [ "$pool_defined" = 1 ]; then
    virsh -c "$LIBVIRT_URI" pool-destroy  "$LIBVIRT_POOL_NAME" 2>/dev/null || true
    virsh -c "$LIBVIRT_URI" pool-undefine "$LIBVIRT_POOL_NAME" 2>/dev/null || true
    echo "libvirt storage pool '${LIBVIRT_POOL_NAME}' removed."
fi

echo
echo "Uninstall complete."
if [ "$kept_count" = 0 ] && [ -d "$LIBVIRT_POOL_PARENT" ]; then
    echo "(Empty pool directory ${LIBVIRT_POOL_PARENT}/ left in place; rm -rf it yourself for a true reset.)"
fi
