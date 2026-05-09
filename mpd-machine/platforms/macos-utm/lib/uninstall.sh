#!/bin/bash
# uninstall.sh — undo host networking, then (per-VM y/N) delete mpd VMs.
# Called by uninstall.command.
#
# Order is deliberate: host cleanup runs first, VM deletion is the last
# step. Ctrl-C during the per-VM prompts therefore leaves the host fully
# cleaned up with the remaining VMs intact — the user can still reach a
# kept VM by re-running setup.command (which restores host networking).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

# --- Discover VMs ---

vms=()
while IFS=$'\t' read -r name state; do
    [ -n "$name" ] && vms+=("${name}|${state}")
done < <(get_mpd_vms)

# --- Detect host cleanup targets (read-only — no sudo needed) ---
# Globals it sets: remove_route, remove_resolver, ca_targets[].
# Called twice: once for the upfront banner / sudo recipe, once after
# the recipe to see what (if anything) the dev already ran manually.

remove_route=0
remove_resolver=0
ca_targets=()

detect_host_targets() {
    remove_route=0
    remove_resolver=0
    ca_targets=()

    local cur_out cur_dest
    cur_out=$(route -n get -inet "$CONTAINER_PROBE_IP" 2>/dev/null || true)
    cur_dest=$(awk '/destination:/ { print $2; exit }' <<<"$cur_out")
    [[ "$cur_dest" == 10.163.0* ]] && remove_route=1

    [ -f "/etc/resolver/${DNS_DOMAIN}" ] && remove_resolver=1

    # Tracked fingerprint from configure-client.sh / setup.sh — only count
    # it if the cert is still present in the keychain (the user might have
    # removed it via Keychain Access).
    if [ -f "$STATE_CA_FILE" ]; then
        local tracked_fp
        tracked_fp=$(cat "$STATE_CA_FILE" 2>/dev/null | tr 'a-f' 'A-F')
        if [ -n "$tracked_fp" ] \
           && security find-certificate -Z "$tracked_fp" "$SYSTEM_KEYCHAIN" >/dev/null 2>&1; then
            ca_targets+=("$tracked_fp")
        fi
    fi

    # Sweep for any other mpd CA certs in the System keychain by subject.
    while IFS= read -r fp; do
        [ -z "$fp" ] && continue
        local skip=0 existing
        for existing in "${ca_targets[@]:-}"; do
            [ -z "$existing" ] && continue
            [ "$existing" = "$fp" ] && { skip=1; break; }
        done
        [ "$skip" = 1 ] && continue
        local pem subj
        pem=$(security find-certificate -Z "$fp" -p "$SYSTEM_KEYCHAIN" 2>/dev/null) || continue
        subj=$(echo "$pem" | openssl x509 -noout -subject 2>/dev/null || true)
        if echo "$subj" | grep -qi "$CA_SUBJECT_MATCH"; then
            ca_targets+=("$fp")
        fi
    done < <(security find-certificate -a -Z "$SYSTEM_KEYCHAIN" 2>/dev/null \
                | awk '/^SHA-1 hash:/ { print $3 }')
}

detect_host_targets

# --- Banner + confirmation ---

echo
echo "This will undo mpd-machine setup on this Mac."
echo
echo "Host networking and state to remove:"
[ "$remove_route" = 1 ]      && echo "    - persistent route to ${CONTAINER_SUBNET_PREFIX}"
[ "$remove_resolver" = 1 ]   && echo "    - /etc/resolver/${DNS_DOMAIN}"
[ ${#ca_targets[@]} -gt 0 ]  && echo "    - mpd CA certificate(s) from System keychain (${#ca_targets[@]})"
echo "    - ${STATE_DIR}"
echo "    - 'Host mpd-machine' block from ~/.ssh/config"
echo "    - ${DESKTOP_SHORTCUT}"
echo

if [ ${#vms[@]} -eq 0 ]; then
    echo "Existing mpd VMs: (none)"
else
    echo "Existing mpd VMs (you'll be asked about each individually at the end):"
    for entry in "${vms[@]}"; do
        echo "    ${entry%|*}  (${entry#*|})"
    done
    echo
    echo "If you keep any VM, host networking will still be removed; re-run"
    echo "setup.command later with that VM's number to restore it."
fi
echo

read -r -p "Type YES to proceed: " confirm
if [ "$confirm" != "YES" ]; then
    echo "Aborted."
    exit 0
fi

# Drop cached sudo credentials whenever this script exits (success, error, or
# Ctrl-C) — backstop in case the explicit sudo -k after the fenced block is
# missed for any reason.
trap 'sudo -k 2>/dev/null || true' EXIT

# --- Host cleanup (sudo recipe affordance) ---

if [ "$remove_route" = 1 ] || [ "$remove_resolver" = 1 ] || [ ${#ca_targets[@]} -gt 0 ]; then
    cmds=()
    [ "$remove_route" = 1 ]    && cmds+=("sudo route -n delete -net ${CONTAINER_SUBNET_PREFIX}")
    [ "$remove_resolver" = 1 ] && cmds+=("sudo rm -f /etc/resolver/${DNS_DOMAIN}")
    for fp in "${ca_targets[@]}"; do
        cmds+=("sudo security delete-certificate -Z ${fp} ${SYSTEM_KEYCHAIN}")
    done

    print_sudo_recipe "${cmds[@]}"

    # Re-check: did the dev already run them in another terminal?
    detect_host_targets

    if [ "$remove_route" = 0 ] && [ "$remove_resolver" = 0 ] && [ ${#ca_targets[@]} -eq 0 ]; then
        ok "host cleanup already complete (you ran the recipe manually)"
    else
        sudo -v || die "sudo authentication failed."
        if [ "$remove_route" = 1 ]; then
            sudo route -n delete -net "$CONTAINER_SUBNET_PREFIX" >/dev/null 2>&1 || true
            echo "Container subnet route removed."
        fi
        if [ "$remove_resolver" = 1 ]; then
            sudo rm -f "/etc/resolver/${DNS_DOMAIN}"
            echo "/etc/resolver/${DNS_DOMAIN} removed."
        fi
        for fp in "${ca_targets[@]}"; do
            sudo security delete-certificate -Z "$fp" "$SYSTEM_KEYCHAIN" >/dev/null 2>&1 || true
            echo "mpd CA certificate removed (sha1 $(echo "$fp" | tr 'A-F' 'a-f'))."
        done
        sudo -k 2>/dev/null || true
    fi
else
    ok "no host networking changes needed (already clean)"
fi

# --- Local file cleanup (no sudo) ---

if [ -d "$STATE_DIR" ]; then
    rm -rf "$STATE_DIR"
    echo "${STATE_DIR} removed."
fi

remove_mpd_ssh_config
echo "SSH config block removed."

if [ -e "$DESKTOP_SHORTCUT" ]; then
    rm -f "$DESKTOP_SHORTCUT"
    echo "Desktop shortcut removed."
fi

# --- Per-VM deletion (last step — Ctrl-C here is safe) ---
# Default is keep: empty input or 'n' preserves the VM. This guards the
# active VM the dev may live in. UTM can delete kept VMs manually later.

if [ ${#vms[@]} -gt 0 ]; then
    echo
    echo "VM deletion (default keeps each VM — press Enter or 'n' to skip):"
    for entry in "${vms[@]}"; do
        name="${entry%|*}"
        state="${entry#*|}"
        read -r -p "    Delete ${name} (${state})? [y/N]: " ans
        if [[ "$ans" =~ ^[Yy] ]]; then
            if [ "$state" != "stopped" ]; then
                echo "    Stopping ${name} ..."
                vm_force_stop "$name" 2>/dev/null || true
                # UTM/utmctl status updates lag ~15s after a stop; poll up to 20s.
                elapsed=0
                while [ "$elapsed" -lt 20 ]; do
                    [ "$(get_vm_state "$name")" = "stopped" ] && break
                    sleep 1
                    elapsed=$((elapsed + 1))
                done
            fi
            echo "    Deleting ${name} ..."
            vm_delete "$name" 2>/dev/null \
                || warn "Could not delete ${name} via AppleScript — remove it from UTM manually."
        else
            echo "    Kept ${name}."
        fi
    done
fi

echo
echo "Uninstall complete."
