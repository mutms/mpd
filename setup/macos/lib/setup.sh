#!/bin/bash
# setup.sh — Create a new mpd-vm VM in Parallels Desktop Pro or
# switch the active VM. Called by setup.command.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

# --- Prereq checks ---

step "Checking prerequisites"

if [ ! -d "/Applications/Parallels Desktop.app" ]; then
    die "Parallels Desktop.app not found in /Applications/. Install Parallels Desktop Pro from https://www.parallels.com/."
fi
[ -x "$PRLCTL" ] \
    || die "prlctl not found at $PRLCTL — Parallels Desktop Pro may need to be reinstalled."
ok "Parallels Desktop Pro installed"

if ! template_exists; then
    die "Parallels template '${TEMPLATE_NAME}' not found. Prepare it per setup/macos/README.md."
fi
ok "Template '${TEMPLATE_NAME}' available"

for tool in ssh ssh-keygen scp security route openssl awk; do
    command -v "$tool" >/dev/null 2>&1 \
        || die "$tool not found on PATH (should be present on every macOS — check your shell setup)."
done
ok "Host tools available"

# --- SSH key ---

step "SSH key"
SSH_KEY=""
for key in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    [ -f "$key" ] && { SSH_KEY="$key"; break; }
done
if [ -z "$SSH_KEY" ]; then
    echo
    echo "    No SSH key found at ~/.ssh/id_ed25519."
    echo "    You need one so the scripts can log into the VM automatically."
    echo
    read -r -p "    Press Enter to generate ~/.ssh/id_ed25519 now (Ctrl-C to abort): " _
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" \
        || die "ssh-keygen failed."
    SSH_KEY="$HOME/.ssh/id_ed25519.pub"
fi
ok "SSH key: $SSH_KEY"

# --- VM selection ---

step "VM selection"

# Tracked VMs come from ~/.mpd-virt/<uuid>.env files; get_mpd_vms
# resolves the current friendly name + state from prlctl. Lines look
# like "<uuid>\t<name>\t<state>".
current_uuid=$(get_current_vm_uuid)
vm_lines=()
while IFS= read -r line; do
    vm_lines+=("$line")
done < <(get_mpd_vms)

echo
SELECTED_UUID=""
SELECTED_NAME=""
SELECTED_IP=""
SELECTED_USER=""
NEW_VM=0

if [ ${#vm_lines[@]} -gt 0 ]; then
    echo "    Existing mpd VMs:"
    default_idx=1
    idx=0
    for line in "${vm_lines[@]}"; do
        idx=$((idx + 1))
        uuid=$(awk -F'\t' '{print $1}' <<<"$line")
        name=$(awk -F'\t' '{print $2}' <<<"$line")
        state=$(awk -F'\t' '{print $3}' <<<"$line")
        tag=""
        if [ -n "$current_uuid" ] && [ "$uuid" = "$current_uuid" ]; then
            tag="  <-- current"
            default_idx=$idx
        fi
        printf '      [%d]  %-24s %-10s %s\n' "$idx" "$name" "$state" "$tag"
    done
    echo
    prompt="Pick a VM by number [${default_idx}], or 'n' for a new VM: "
else
    echo "    No mpd VMs found yet."
    echo
    default_idx=""
    prompt="Press Enter (or 'n') to create the first mpd VM: "
fi

while :; do
    read -r -p "    $prompt" inp
    inp="${inp:-${default_idx:-n}}"
    if [[ "$inp" =~ ^[Nn]$ ]] || [ -z "$inp" ]; then
        NEW_VM=1
        break
    fi
    if [[ "$inp" =~ ^[0-9]+$ ]] && [ "$inp" -ge 1 ] && [ "$inp" -le ${#vm_lines[@]} ]; then
        sel="${vm_lines[$((inp - 1))]}"
        SELECTED_UUID=$(awk -F'\t' '{print $1}' <<<"$sel")
        SELECTED_NAME=$(awk -F'\t' '{print $2}' <<<"$sel")
        SELECTED_IP=$(get_vm_ip_by_uuid "$SELECTED_UUID")
        SELECTED_USER=$(get_vm_ssh_user_by_uuid "$SELECTED_UUID")
        break
    fi
    echo "    Enter a number in [1..${#vm_lines[@]}] to pick an existing VM, or 'n' to create a new one."
done

# --- Branch on selection ---

if [ "$NEW_VM" = 0 ]; then
    VM_UUID="$SELECTED_UUID"
    VM_NAME="$SELECTED_NAME"
    VM_IP="$SELECTED_IP"
    VM_USER="$SELECTED_USER"

    if [ "$VM_UUID" = "${current_uuid:-}" ]; then
        # ── Re-verify current VM ──────────────────────────────────────────
        step "Re-verifying current VM (${VM_NAME} at ${VM_IP})"

        state=$(get_vm_state "$VM_UUID")
        if [ "$state" != "running" ]; then
            echo "    VM state is ${state} — starting..."
            vm_start "$VM_UUID"
            wait_for_ssh "$VM_IP" "$VM_USER" 120 \
                || die "SSH not available after 120s."
            ok "VM online"
        else
            ok "VM already running"
        fi
    else
        # ── Switch to a different VM ──────────────────────────────────────
        current_name=""
        if [ -n "${current_uuid:-}" ]; then
            current_name=$(get_vm_name_by_uuid "$current_uuid")
        fi
        current_name="${current_name:-(none)}"
        echo
        read -r -p "    Suspend ${current_name} and switch to ${VM_NAME}? [Y/n]: " inp
        if [ -n "$inp" ] && [[ ! "$inp" =~ ^[Yy] ]]; then
            echo "    Aborted."
            exit 0
        fi

        if [ -n "${current_uuid:-}" ] \
           && vm_exists "$current_uuid" \
           && [ "$(get_vm_state "$current_uuid")" = "running" ]; then
            step "Suspending ${current_name}"
            vm_suspend "$current_uuid"
            ok "Suspended"
        fi

        clear_known_hosts

        step "Starting ${VM_NAME}"
        vm_start "$VM_UUID"
        wait_for_ssh "$VM_IP" "$VM_USER" 180 \
            || die "SSH not available after 180s."
        ok "SSH ready"
    fi

    bash "${SCRIPT_DIR}/configure-client.sh" --vm-ip="$VM_IP" --vm-user="$VM_USER"

else
    # ── Create new VM ────────────────────────────────────────────────────
    echo
    echo "    Cloning a new VM from template '${TEMPLATE_NAME}'."
    echo

    # IP octet (drives the VM's static IP, default Parallels name, and host
    # route). User can rename the VM in Parallels later; mpd tracks by UUID
    # so the rename is invisible to the host-side state files.
    VM_OCTET=""
    while [ -z "$VM_OCTET" ]; do
        read -r -p "    Last IP octet for the new VM [155] (must be ${MIN_STATIC_OCTET}–${MAX_STATIC_OCTET}, since Parallels DHCP owns .1–.$(($MIN_STATIC_OCTET - 1))): " inp
        inp="${inp:-155}"
        if [[ "$inp" =~ ^[0-9]+$ ]] \
           && [ "$inp" -ge "$MIN_STATIC_OCTET" ] && [ "$inp" -le "$MAX_STATIC_OCTET" ]; then
            # Reject if an existing tracked VM already uses this IP.
            existing_uuid=$(get_uuid_by_ip "${BRIDGE_SUBNET}.${inp}")
            if [ -n "$existing_uuid" ]; then
                existing_name=$(get_vm_name_by_uuid "$existing_uuid")
                echo "    Octet ${inp} is already used by VM '${existing_name}' (uuid=${existing_uuid}). Pick a different octet, or select that VM from the list above."
            else
                VM_OCTET="$inp"
            fi
        else
            echo "    Please enter a number between ${MIN_STATIC_OCTET} and ${MAX_STATIC_OCTET}."
        fi
    done

    VM_NAME="${VM_NAME_PREFIX}${VM_OCTET}"
    VM_IP="${BRIDGE_SUBNET}.${VM_OCTET}"

    # Refuse if Parallels already has a VM under that initial name (we
    # only collide on the name we'd create — a renamed VM at the same IP
    # was already caught above by the IP check).
    if vm_exists "$VM_NAME"; then
        die "Parallels already has a VM named '${VM_NAME}'. Delete it or pick a different octet."
    fi

    # Username
    user_guess=$(whoami | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
    [ -z "$user_guess" ] && user_guess="dev"
    VM_USER=""
    while [ -z "$VM_USER" ]; do
        read -r -p "    Username on the VM (must already exist in the template) [${user_guess}]: " inp
        inp="${inp:-$user_guess}"
        if [[ "$inp" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
            VM_USER="$inp"
        else
            echo "    Username must start with a letter or digit and contain only a-z, 0-9, hyphens."
        fi
    done

    # Memory (GB)
    VM_MEMORY_GB=""
    while [ -z "$VM_MEMORY_GB" ]; do
        read -r -p "    Memory in GB [12]: " inp
        inp="${inp:-12}"
        if [[ "$inp" =~ ^[0-9]+$ ]] && [ "$inp" -ge 2 ]; then
            VM_MEMORY_GB="$inp"
        else
            echo "    Memory must be a whole number of GB >= 2."
        fi
    done

    # Disk (GB)
    VM_DISK_SIZE=""
    while [ -z "$VM_DISK_SIZE" ]; do
        read -r -p "    Disk size in GB [200]: " inp
        inp="${inp:-200}"
        if [[ "$inp" =~ ^[0-9]+$ ]] && [ "$inp" -ge 8 ]; then
            VM_DISK_SIZE="$inp"
        else
            echo "    Disk size must be a whole number of GB >= 8."
        fi
    done

    # ── Host-side preparation: CA + upfront fenced sudo ─────────────────

    step "Preparing CA on host"
    prepare_host_ca
    trap 'sudo -k 2>/dev/null || true' EXIT

    needs=()
    if route_needs_update    "$VM_IP";        then needs+=(route);    fi
    if resolver_needs_update;                  then needs+=(resolver); fi
    if ! ca_in_keychain      "$HOST_CA_PEM";  then needs+=(ca);       fi

    if [ ${#needs[@]} -gt 0 ]; then
        cmds=()
        case " ${needs[*]} " in *" route "*)
            probe_out=$(route -n get -inet "$CONTAINER_PROBE_IP" 2>/dev/null || true)
            probe_dest=$(awk '/destination:/ { print $2; exit }' <<<"$probe_out")
            probe_gw=$(awk   '/gateway:/    { print $2; exit }' <<<"$probe_out")
            if [[ "$probe_dest" == 10.163.0* ]] && [ -n "$probe_gw" ]; then
                cmds+=("sudo route -n delete -net ${CONTAINER_SUBNET_PREFIX}")
            fi
            cmds+=("sudo route -n add -net ${CONTAINER_SUBNET_PREFIX} ${VM_IP}")
        ;; esac
        case " ${needs[*]} " in *" resolver "*)
            cmds+=("sudo mkdir -p /etc/resolver")
            cmds+=("printf 'nameserver ${DNSMASQ_IP}\\n' | sudo tee /etc/resolver/${DNS_DOMAIN} >/dev/null")
            cmds+=("sudo chmod 0644 /etc/resolver/${DNS_DOMAIN}")
        ;; esac
        case " ${needs[*]} " in *" ca "*)
            cmds+=("sudo security add-trusted-cert -d -r trustRoot -k ${SYSTEM_KEYCHAIN} \"${HOST_CA_PEM}\"")
        ;; esac

        print_sudo_recipe "${cmds[@]}"

        needs2=()
        if route_needs_update    "$VM_IP";        then needs2+=(route);    fi
        if resolver_needs_update;                  then needs2+=(resolver); fi
        if ! ca_in_keychain      "$HOST_CA_PEM";  then needs2+=(ca);       fi

        if [ ${#needs2[@]} -eq 0 ]; then
            ok "all operations already complete (you ran them manually)"
        else
            sudo -v || die "sudo authentication failed."
            case " ${needs2[*]} " in *" route "*)    apply_route        "$VM_IP"       ;; esac
            case " ${needs2[*]} " in *" resolver "*) apply_resolver                     ;; esac
            case " ${needs2[*]} " in *" ca "*)       apply_ca_from_file "$HOST_CA_PEM" ;; esac
            sudo -k 2>/dev/null || true
            ok "host networking + CA trust applied"
        fi

        if ca_in_keychain "$HOST_CA_PEM"; then
            record_ca_fingerprint "$HOST_CA_PEM"
        fi
    else
        ok "host already configured for ${VM_IP}; no sudo needed"
    fi

    # Suspend any currently-active VM before we create.
    if [ -n "${current_uuid:-}" ] \
       && vm_exists "$current_uuid" \
       && [ "$(get_vm_state "$current_uuid")" = "running" ]; then
        cur_name=$(get_vm_name_by_uuid "$current_uuid")
        step "Suspending ${cur_name:-${current_uuid}}"
        vm_suspend "$current_uuid"
        ok "Suspended"
    fi

    echo
    echo "    Cloning VM: name=${VM_NAME}  IP=${VM_IP}  user=${VM_USER}  memory=${VM_MEMORY_GB}GB  disk=${VM_DISK_SIZE}GB"
    echo

    # create-vm.sh writes the new VM's UUID to this file on success.
    NEW_VM_UUID_FILE=$(mktemp -t mpd-new-vm-uuid)
    trap '
        sudo -k 2>/dev/null || true
        rm -f "$NEW_VM_UUID_FILE"
    ' EXIT

    MPD_NEW_VM_UUID_FILE="$NEW_VM_UUID_FILE" bash "${SCRIPT_DIR}/create-vm.sh" \
        --octet="$VM_OCTET" \
        --user="$VM_USER" \
        --ssh-pub-key="$SSH_KEY" \
        --memory-gb="$VM_MEMORY_GB" \
        --disk-gb="$VM_DISK_SIZE" \
        --host-ca-pem="$HOST_CA_PEM" \
        --host-ca-key="$HOST_CA_KEY"

    VM_UUID=$(<"$NEW_VM_UUID_FILE")
    [ -n "$VM_UUID" ] || die "create-vm.sh did not record a UUID at ${NEW_VM_UUID_FILE}."

    # Pre-warm demo stack so the user's first `demo moodle …` is fast.
    step "Pre-warming demo runtime and database"
    if ssh_cmd "$VM_IP" "$VM_USER" 'mpd --runtime-create=php'; then
        ok "PHP runtime built"
    else
        warn "PHP runtime pre-warm failed; demo will provision on first run"
    fi
    if ssh_cmd "$VM_IP" "$VM_USER" 'mpd --db-create=postgres:latest'; then
        ok "postgres:latest ready"
    else
        warn "postgres:latest pre-warm failed; demo will provision on first run"
    fi
fi

# --- State refresh ---
# Re-resolve the friendly name from Parallels (the user may have renamed
# it between setup runs); we use the current name in the SSH config
# alias and as the snapshot in current.env.

resolved_name=$(get_vm_name_by_uuid "$VM_UUID")
[ -n "$resolved_name" ] && VM_NAME="$resolved_name"

set_mpd_ssh_config    "$VM_NAME" "$VM_IP" "$VM_USER"
write_mpd_current_env "$VM_UUID" "$VM_NAME" "$VM_IP" "$VM_USER"
ensure_desktop_shortcut

# --- Done ---

echo
echo "============================================="
echo "  Your mpd VM (${VM_NAME}) is ready!"
echo "  Double-click ~/Desktop/mpd-vm.command"
echo "  to connect, or run: ssh ${VM_NAME}"
echo "============================================="
echo
