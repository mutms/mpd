#!/bin/bash
# uninstall.sh — delete all mpd VMs and undo host networking.
# Called by uninstall.command.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

vms=()
while IFS=$'\t' read -r name state; do
    [ -n "$name" ] && vms+=("${name}|${state}")
done < <(get_mpd_vms)

echo
echo "This will permanently DELETE the following VMs and remove host networking:"
echo
if [ ${#vms[@]} -eq 0 ]; then
    echo "    (no ${VM_NAME_PREFIX}NN VMs found)"
else
    for entry in "${vms[@]}"; do
        echo "    ${entry%|*}  (${entry#*|})"
    done
fi
echo
echo "It will also remove:"
echo "    - persistent route to ${CONTAINER_SUBNET_PREFIX}"
echo "    - /etc/resolver/${DNS_DOMAIN}"
echo "    - mpd CA certificate from System keychain"
echo "    - ${STATE_DIR} (current.env, per-VM env files)"
echo "    - 'Host mpd-machine' block from ~/.ssh/config"
echo "    - ${DESKTOP_SHORTCUT}"
echo
read -r -p "Type YES to confirm: " confirm
if [ "$confirm" != "YES" ]; then
    echo "Aborted."
    exit 0
fi

# Drop cached sudo credentials whenever this script exits (success, error, or
# early termination) — backstop in case the explicit sudo -k after the fenced
# block is missed for any reason.
trap 'sudo -k 2>/dev/null || true' EXIT

# --- Stop and delete VMs ---

for entry in "${vms[@]}"; do
    name="${entry%|*}"
    state="${entry#*|}"
    if [ "$state" != "stopped" ]; then
        echo "Stopping ${name} ..."
        vm_force_stop "$name" 2>/dev/null || true
        # Wait briefly for stop to complete.
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            [ "$(get_vm_state "$name")" = "stopped" ] && break
            sleep 1
        done
    fi
    echo "Deleting ${name} ..."
    vm_delete "$name" 2>/dev/null || warn "Could not delete ${name} via AppleScript — remove it from UTM manually."
done

# --- Privileged cleanup (single fenced block, drops sudo at end) ---
# All `sudo` calls live here and only here. Discovery (`route get`,
# `security find-certificate -p`, `openssl`) doesn't need elevation, so
# it's done outside the block; the block contains only the actual writes.

cur_out=$(route -n get -inet "$CONTAINER_PROBE_IP" 2>/dev/null || true)
cur_dest=$(awk '/destination:/ { print $2; exit }' <<<"$cur_out")
remove_route=0
[[ "$cur_dest" == 10.163.0* ]] && remove_route=1

remove_resolver=0
[ -f "/etc/resolver/${DNS_DOMAIN}" ] && remove_resolver=1

# Discover certs to delete (no sudo for read).
ca_targets=()
if [ -f "$STATE_CA_FILE" ]; then
    tracked_fp=$(cat "$STATE_CA_FILE" 2>/dev/null | tr 'a-f' 'A-F')
    [ -n "$tracked_fp" ] && ca_targets+=("$tracked_fp")
fi
while IFS= read -r fp; do
    [ -z "$fp" ] && continue
    # Skip if already in targets.
    skip=0
    for existing in "${ca_targets[@]}"; do
        [ "$existing" = "$fp" ] && { skip=1; break; }
    done
    [ "$skip" = 1 ] && continue
    pem=$(security find-certificate -Z "$fp" -p "$SYSTEM_KEYCHAIN" 2>/dev/null) || continue
    subj=$(echo "$pem" | openssl x509 -noout -subject 2>/dev/null || true)
    if echo "$subj" | grep -qi "$CA_SUBJECT_MATCH"; then
        ca_targets+=("$fp")
    fi
done < <(security find-certificate -a -Z "$SYSTEM_KEYCHAIN" 2>/dev/null \
            | awk '/^SHA-1 hash:/ { print $3 }')

if [ "$remove_route" = 1 ] || [ "$remove_resolver" = 1 ] || [ ${#ca_targets[@]} -gt 0 ]; then
    echo
    echo "macOS will ask for your password to:"
    [ "$remove_route" = 1 ]    && echo "    - remove route ${CONTAINER_SUBNET_PREFIX}"
    [ "$remove_resolver" = 1 ] && echo "    - remove /etc/resolver/${DNS_DOMAIN}"
    [ ${#ca_targets[@]} -gt 0 ] && echo "    - remove ${#ca_targets[@]} mpd CA cert(s) from the System keychain"
    sudo -v || die "sudo authentication failed."

    if [ "$remove_route" = 1 ]; then
        sudo route -n delete -net "$CONTAINER_SUBNET_PREFIX" >/dev/null 2>&1 || true
    fi
    if [ "$remove_resolver" = 1 ]; then
        sudo rm -f "/etc/resolver/${DNS_DOMAIN}"
    fi
    for fp in "${ca_targets[@]}"; do
        sudo security delete-certificate -Z "$fp" "$SYSTEM_KEYCHAIN" >/dev/null 2>&1 || true
    done

    sudo -k 2>/dev/null || true
fi

# Reporting (no sudo from here on).
[ "$remove_route" = 1 ]    && echo "Container subnet route removed."
[ "$remove_resolver" = 1 ] && echo "/etc/resolver/${DNS_DOMAIN} removed."
for fp in "${ca_targets[@]}"; do
    echo "mpd CA certificate removed (sha1 $(echo "$fp" | tr 'A-F' 'a-f'))."
done

# --- Remove state dir ---

if [ -d "$STATE_DIR" ]; then
    rm -rf "$STATE_DIR"
    echo "${STATE_DIR} removed."
fi

# --- Remove SSH config block ---

remove_mpd_ssh_config
echo "SSH config block removed."

# --- Remove Desktop shortcut ---

if [ -e "$DESKTOP_SHORTCUT" ]; then
    rm -f "$DESKTOP_SHORTCUT"
    echo "Desktop shortcut removed."
fi

echo
echo "Uninstall complete."
