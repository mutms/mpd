#!/bin/bash
# setup.sh — Create a new mpd-machine VM in Parallels Desktop Pro or
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

current_octet=$(get_current_vm_octet)
vm_lines=()
while IFS= read -r line; do
    vm_lines+=("$line")
done < <(get_mpd_vms)

echo
if [ ${#vm_lines[@]} -gt 0 ]; then
    echo "    Existing mpd VMs:"
    for line in "${vm_lines[@]}"; do
        name=$(awk '{print $1}' <<<"$line")
        state=$(awk '{print $2}' <<<"$line")
        octet=$(extract_octet "$name")
        tag=""
        [ -n "$octet" ] && [ "$octet" = "$current_octet" ] && tag="  <-- current"
        printf '      %-22s %s%s\n' "$name" "$state" "$tag"
    done
    echo

    default_octet="$current_octet"
    if [ -z "$default_octet" ] \
       || ! printf '%s\n' "${vm_lines[@]}" | awk '{print $1}' \
            | grep -qx "${VM_NAME_PREFIX}${default_octet}"; then
        first_name=$(awk '{print $1}' <<<"${vm_lines[0]}")
        default_octet=$(extract_octet "$first_name")
    fi
    if [ -n "$default_octet" ]; then
        prompt="Enter VM number [${default_octet}]: "
    else
        prompt="Enter VM number: "
    fi
else
    echo "    No mpd VMs found yet."
    echo
    default_octet="155"
    prompt="Enter last IP octet for the new VM [${default_octet}] (must be ${MIN_STATIC_OCTET}–${MAX_STATIC_OCTET}, since Parallels DHCP owns .1–.$(($MIN_STATIC_OCTET - 1))): "
fi

VM_OCTET=""
while [ -z "$VM_OCTET" ]; do
    read -r -p "    $prompt" inp
    inp="${inp:-$default_octet}"
    if [[ "$inp" =~ ^[0-9]+$ ]] \
       && [ "$inp" -ge "$MIN_STATIC_OCTET" ] && [ "$inp" -le "$MAX_STATIC_OCTET" ]; then
        VM_OCTET="$inp"
    else
        echo "    Please enter a number between ${MIN_STATIC_OCTET} and ${MAX_STATIC_OCTET} (the Parallels Shared DHCP pool owns .1–.$(($MIN_STATIC_OCTET - 1)))."
    fi
done

VM_NAME="${VM_NAME_PREFIX}${VM_OCTET}"
VM_IP="${BRIDGE_SUBNET}.${VM_OCTET}"

# --- Branch on selection ---

if vm_exists "$VM_NAME"; then
    VM_USER=$(get_vm_ssh_user "$VM_NAME")

    if [ "$VM_OCTET" = "${current_octet:-}" ]; then
        # ── Re-verify current VM ──────────────────────────────────────────
        step "Re-verifying current VM (${VM_NAME} at ${VM_IP})"

        state=$(get_vm_state "$VM_NAME")
        if [ "$state" != "running" ]; then
            echo "    VM state is ${state} — starting..."
            vm_start "$VM_NAME"
            wait_for_ssh "$VM_IP" "$VM_USER" 120 \
                || die "SSH not available after 120s."
            ok "VM online"
        else
            ok "VM already running"
        fi
    else
        # ── Switch to a different VM ──────────────────────────────────────
        current_name="${current_octet:+${VM_NAME_PREFIX}${current_octet}}"
        current_name="${current_name:-(none)}"
        echo
        read -r -p "    Suspend ${current_name} and switch to ${VM_NAME}? [Y/n]: " inp
        if [ -n "$inp" ] && [[ ! "$inp" =~ ^[Yy] ]]; then
            echo "    Aborted."
            exit 0
        fi

        if [ -n "${current_octet:-}" ]; then
            cur="${VM_NAME_PREFIX}${current_octet}"
            if vm_exists "$cur" && [ "$(get_vm_state "$cur")" = "running" ]; then
                step "Suspending ${cur}"
                vm_suspend "$cur"
                ok "Suspended"
            fi
        fi

        clear_known_hosts

        step "Starting ${VM_NAME}"
        vm_start "$VM_NAME"
        wait_for_ssh "$VM_IP" "$VM_USER" 180 \
            || die "SSH not available after 180s."
        ok "SSH ready"
    fi

    bash "${SCRIPT_DIR}/configure-client.sh" --vm-ip="$VM_IP" --vm-user="$VM_USER"

else
    # ── Create new VM ────────────────────────────────────────────────────
    echo
    echo "    No VM named '${VM_NAME}' found — cloning from '${TEMPLATE_NAME}'."
    echo

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
    if [ -n "${current_octet:-}" ]; then
        cur="${VM_NAME_PREFIX}${current_octet}"
        if vm_exists "$cur" && [ "$(get_vm_state "$cur")" = "running" ]; then
            step "Suspending ${cur}"
            vm_suspend "$cur"
            ok "Suspended"
        fi
    fi

    echo
    echo "    Cloning VM: name=${VM_NAME}  IP=${VM_IP}  user=${VM_USER}  memory=${VM_MEMORY_GB}GB  disk=${VM_DISK_SIZE}GB"
    echo

    bash "${SCRIPT_DIR}/create-vm.sh" \
        --octet="$VM_OCTET" \
        --user="$VM_USER" \
        --ssh-pub-key="$SSH_KEY" \
        --memory-gb="$VM_MEMORY_GB" \
        --disk-gb="$VM_DISK_SIZE" \
        --host-ca-pem="$HOST_CA_PEM" \
        --host-ca-key="$HOST_CA_KEY"

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

set_mpd_ssh_config    "$VM_NAME" "$VM_IP" "$VM_USER"
write_mpd_current_env "$VM_NAME" "$VM_IP" "$VM_USER"
ensure_desktop_shortcut

# --- Done ---

echo
echo "============================================="
echo "  Your mpd VM (${VM_NAME}) is ready!"
echo "  Double-click ~/Desktop/mpd-machine.command"
echo "  to connect, or run: ssh ${VM_NAME}"
echo "============================================="
echo
