#!/bin/bash
# setup.sh — Pre-flight + create/switch an mpd-vm VM (linux).
# Called by the entry shim at ../setup.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

# ============================================================
# Stage 0 — Pre-flight
# ============================================================

step "Pre-flight checks"

user_only=()
sudo_descriptions=()
sudo_recipe=()
optional_recipe=()

# --- Ubuntu 26.04 ---
ver=$(awk -F= '$1=="VERSION_ID" { gsub("\"",""); print $2 }' /etc/os-release 2>/dev/null)
id_field=$(awk -F= '$1=="ID" { gsub("\"",""); print $2 }' /etc/os-release 2>/dev/null)
if [ "$id_field" != "ubuntu" ] || [ "$ver" != "26.04" ]; then
    user_only+=("This script targets Ubuntu 26.04 LTS; detected ${id_field:-unknown}/${ver:-unknown}.")
fi

# --- Hardware virtualization ---
if [ ! -e /dev/kvm ]; then
    user_only+=("Enable virtualization in BIOS/UEFI (Intel VT-x / AMD-V) — /dev/kvm is missing.")
fi
if ! grep -m1 -qE '\bvmx\b|\bsvm\b' /proc/cpuinfo; then
    user_only+=("CPU does not advertise virtualization extensions (no vmx/svm in /proc/cpuinfo).")
fi

# --- Required packages ---
required_pkgs=(
    libvirt-daemon-system libvirt-clients
    qemu-system-x86 qemu-utils
    cloud-image-utils genisoimage
    libnss3-tools
)
missing_pkgs=()
for pkg in "${required_pkgs[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing_pkgs+=("$pkg")
done
if [ ${#missing_pkgs[@]} -gt 0 ]; then
    sudo_descriptions+=("Install ${#missing_pkgs[@]} package(s): ${missing_pkgs[*]}")
    sudo_recipe+=("sudo apt-get update")
    sudo_recipe+=("sudo apt-get install -y ${missing_pkgs[*]}")
fi

# --- virt-manager (recommended, optional) ---
if ! dpkg -s virt-manager >/dev/null 2>&1; then
    optional_recipe+=("sudo apt-get install -y virt-manager")
fi

# --- libvirt group (system DB + active in current shell) ---
in_etc_group=0
in_current_shell=0
if getent group libvirt 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n' | grep -qx "$USER"; then
    in_etc_group=1
fi
if id -nG | tr ' ' '\n' | grep -qx libvirt; then
    in_current_shell=1
fi

libvirt_group_just_added=0
if [ "$in_current_shell" = 0 ]; then
    if [ "$in_etc_group" = 1 ]; then
        user_only+=("libvirt group membership exists in /etc/group but isn't active in this shell — log out and log back in (or 'exec newgrp libvirt' if available), then re-run setup.sh.")
    else
        sudo_descriptions+=("Add $USER to the libvirt group")
        sudo_recipe+=("sudo usermod -aG libvirt $USER")
        libvirt_group_just_added=1
    fi
fi

# --- VM disk pool directory at /var/lib/mpd-virt/$USER ---
# libvirtd accesses VM disks as the libvirt-qemu user; its apparmor profile
# auto-allows libvirt-managed pool paths. Putting the pool in /var/lib keeps
# $HOME's mode untouched and gives a multi-user-safe layout (root-owned
# parent, per-user child).
pool_parent_ok=0
pool_user_dir_ok=0
[ -d "$LIBVIRT_POOL_PARENT" ] && [ "$(stat -c %U "$LIBVIRT_POOL_PARENT" 2>/dev/null)" = "$USER" ] \
    && pool_user_dir_ok=1
[ -d /var/lib/mpd-virt ] && pool_parent_ok=1

if [ "$pool_user_dir_ok" = 0 ]; then
    sudo_descriptions+=("Create VM disk pool directory at ${LIBVIRT_POOL_PARENT} (owned by ${USER})")
    if [ "$pool_parent_ok" = 0 ]; then
        sudo_recipe+=("sudo install -d -m 0755 -o root -g root /var/lib/mpd-virt")
    fi
    sudo_recipe+=("sudo install -d -m 0755 -o ${USER} -g ${USER} ${LIBVIRT_POOL_PARENT}")
fi

# --- libvirt 'default' network — only checkable when group is active here ---
if [ "$in_current_shell" = 1 ] && command -v virsh >/dev/null 2>&1; then
    net_info=$(virsh -c "$LIBVIRT_URI" net-info default 2>/dev/null || true)
    if [ -n "$net_info" ]; then
        active=$(awk -F: '/^Active:/    { sub(/^[[:space:]]*/, "", $2); print $2 }' <<<"$net_info")
        autostart=$(awk -F: '/^Autostart:/ { sub(/^[[:space:]]*/, "", $2); print $2 }' <<<"$net_info")
        if [ "$active" != "yes" ]; then
            sudo_descriptions+=("Start libvirt 'default' network")
            sudo_recipe+=("sudo virsh -c $LIBVIRT_URI net-start default")
        fi
        if [ "$autostart" != "yes" ]; then
            sudo_descriptions+=("Set libvirt 'default' network to autostart")
            sudo_recipe+=("sudo virsh -c $LIBVIRT_URI net-autostart default")
        fi
    fi
fi

# --- Report + decisions ---

anything_pending=0
[ ${#user_only[@]} -gt 0 ] && anything_pending=1
[ ${#sudo_recipe[@]} -gt 0 ] && anything_pending=1
[ ${#optional_recipe[@]} -gt 0 ] && anything_pending=1

if [ "$anything_pending" = 1 ]; then
    echo
    if [ ${#user_only[@]} -gt 0 ]; then
        echo "    Things only YOU can do:"
        for item in "${user_only[@]}"; do echo "      - $item"; done
        echo
    fi
    if [ ${#sudo_descriptions[@]} -gt 0 ]; then
        echo "    Things this script can do (with sudo):"
        for item in "${sudo_descriptions[@]}"; do echo "      - $item"; done
        echo
    fi
    if [ ${#optional_recipe[@]} -gt 0 ]; then
        echo "    Recommended (optional, included in the recipe text but not"
        echo "    in option (b) auto-install — run yourself if you want it):"
        echo "      - virt-manager — GUI VM list and console access"
        echo
    fi
fi

if [ ${#user_only[@]} -gt 0 ]; then
    echo "    Handle the items above (and any 'sudo' items if you'd rather"
    echo "    do them yourself), then re-run setup.sh."
    if [ ${#sudo_recipe[@]} -gt 0 ] || [ ${#optional_recipe[@]} -gt 0 ]; then
        echo
        echo "    Recipe (run these as root in another terminal):"
        echo
        for cmd in "${sudo_recipe[@]}";   do printf '        %s\n' "$cmd"; done
        for cmd in "${optional_recipe[@]}"; do printf '        %s\n' "$cmd"; done
        printf '        %s\n' "sudo -k"
    fi
    echo
    exit 1
fi

if [ ${#sudo_recipe[@]} -gt 0 ]; then
    printable=()
    for cmd in "${sudo_recipe[@]}";   do printable+=("$cmd"); done
    for cmd in "${optional_recipe[@]}"; do printable+=("$cmd"); done
    print_sudo_recipe "${printable[@]}"

    # Re-detect each sudo-able item so that if the dev ran the recipe in
    # another terminal, we don't re-sudo for things they already did.
    still_missing=()
    for pkg in "${required_pkgs[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || still_missing+=("$pkg")
    done

    pool_user_dir_ok_now=0
    [ -d "$LIBVIRT_POOL_PARENT" ] \
        && [ "$(stat -c %U "$LIBVIRT_POOL_PARENT" 2>/dev/null)" = "$USER" ] \
        && pool_user_dir_ok_now=1

    libvirt_group_in_etc_now=0
    if getent group libvirt 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n' | grep -qx "$USER"; then
        libvirt_group_in_etc_now=1
    fi

    needs_anything=0
    [ ${#still_missing[@]} -gt 0 ] && needs_anything=1
    [ "$pool_user_dir_ok_now" = 0 ] && needs_anything=1
    [ "$libvirt_group_just_added" = 1 ] && [ "$libvirt_group_in_etc_now" = 0 ] && needs_anything=1

    if [ "$needs_anything" = 0 ]; then
        ok "all required prerequisites in place (you ran the recipe manually)"
    else
        echo
        echo "    Applying the still-missing parts via sudo..."
        sudo -v || die "sudo authentication failed."
        if [ ${#still_missing[@]} -gt 0 ]; then
            sudo apt-get update
            sudo apt-get install -y "${still_missing[@]}"
        fi
        if [ "$libvirt_group_just_added" = 1 ] && [ "$libvirt_group_in_etc_now" = 0 ]; then
            sudo usermod -aG libvirt "$USER"
        fi
        if [ "$pool_user_dir_ok_now" = 0 ]; then
            sudo install -d -m 0755 -o root  -g root  /var/lib/mpd-virt
            sudo install -d -m 0755 -o "$USER" -g "$USER" "$LIBVIRT_POOL_PARENT"
        fi
        if command -v virsh >/dev/null 2>&1; then
            sudo virsh -c "$LIBVIRT_URI" net-autostart default 2>/dev/null || true
            sudo virsh -c "$LIBVIRT_URI" net-start default 2>/dev/null || true
        fi
        sudo -k 2>/dev/null || true
        ok "required prereqs applied"
    fi

    if [ "$libvirt_group_just_added" = 1 ]; then
        echo
        echo "    The libvirt group was just added to your account. Group"
        echo "    membership only activates in shells started AFTER the"
        echo "    change, so this shell can't talk to libvirtd yet."
        echo
        echo "    Log out and log back in (or close+reopen your terminal /"
        echo "    SSH session entirely), then re-run setup.sh."
        echo
        exit 0
    fi
fi

# ============================================================
# Stage 1 — SSH key
# ============================================================

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

# ============================================================
# Stage 2 — VM selection
# ============================================================

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
        # State may have spaces ("shut off"); take everything after $1.
        state=$(awk '{$1=""; sub(/^ /,""); print}' <<<"$line")
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
    default_octet="158"
    prompt="Enter last IP octet for the new VM [${default_octet}]: "
fi

VM_OCTET=""
while [ -z "$VM_OCTET" ]; do
    read -r -p "    $prompt" inp
    inp="${inp:-$default_octet}"
    if [[ "$inp" =~ ^[0-9]+$ ]] && [ "$inp" -ge 2 ] && [ "$inp" -le 254 ]; then
        VM_OCTET="$inp"
    else
        echo "    Please enter a number between 2 and 254."
    fi
done

VM_NAME="${VM_NAME_PREFIX}${VM_OCTET}"
VM_IP="${BRIDGE_SUBNET}.${VM_OCTET}"

# This VM's subnet / zone / resolver drop-in, keyed on its id. Everything
# downstream (route, resolver, printed URLs) reads these.
mpd_net_from_vm_ip "$VM_IP"

# ============================================================
# Stage 3 — Branch on selection
# ============================================================

if vm_exists "$VM_NAME"; then
    VM_USER=$(get_vm_ssh_user "$VM_NAME")

    if [ "$VM_OCTET" = "${current_octet:-}" ]; then
        # Re-verify current VM
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
        # Switch to a different VM
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

    set_mpd_ssh_config    "$VM_NAME" "$VM_IP" "$VM_USER"
    write_mpd_current_env "$VM_NAME" "$VM_IP" "$VM_USER"
    ensure_desktop_shortcut

    echo
    echo "============================================="
    echo "  mpd-vm ready."
    echo "  Activities → 'mpd-vm' (or 'ssh mpd-vm')"
    echo "============================================="
    echo
    exit 0
fi

# ----- Create new VM -----

echo
echo "    No VM named '${VM_NAME}' found — creating a new one."
echo

# Username
user_guess=$(whoami | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
[ -z "$user_guess" ] && user_guess="dev"
VM_USER=""
while [ -z "$VM_USER" ]; do
    read -r -p "    Username on the VM [${user_guess}]: " inp
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

# ============================================================
# Stage 4 — Host CA prep + privileged block (recipe affordance)
# ============================================================

step "Preparing CA on host"
prepare_host_ca
trap 'sudo -k 2>/dev/null || true' EXIT

# --- User-level CA trust (no sudo): NSS DB for Chromium-family browsers ---
# Done before the sudo block since it needs no privileges.
if ! ca_in_nssdb "$HOST_CA_PEM"; then
    apply_ca_to_nssdb "$HOST_CA_PEM"
    ok "imported CA into ~/.pki/nssdb (Chromium / Chrome / Edge)"
else
    ok "CA already in ~/.pki/nssdb"
fi

# --- Privileged ops: route + resolver + system trust + Firefox policies ---
needs=()
if route_needs_update    "$VM_IP";          then needs+=(route);    fi
if resolver_needs_update;                    then needs+=(resolver); fi
if ! ca_in_systrust     "$HOST_CA_PEM";    then needs+=(systrust); fi
if firefox_policies_needs_update "$HOST_CA_PEM"; then needs+=(firefox);  fi

if [ ${#needs[@]} -gt 0 ]; then
    cmds=()
    case " ${needs[*]} " in *" route "*)
        cmds+=("sudo ip route replace ${CONTAINER_SUBNET_PREFIX} via ${VM_IP}")
    ;; esac
    case " ${needs[*]} " in *" resolver "*)
        cmds+=("sudo install -d -m 0755 ${RESOLVED_DROPIN_DIR}")
        cmds+=("printf '[Resolve]\\nDNS=${DNSMASQ_IP}\\nDomains=~${DNS_DOMAIN}\\n' | sudo tee ${RESOLVED_DROPIN_FILE} >/dev/null")
        cmds+=("sudo chmod 0644 ${RESOLVED_DROPIN_FILE}")
        cmds+=("sudo systemctl restart systemd-resolved")
    ;; esac
    case " ${needs[*]} " in *" systrust "*)
        cmds+=("sudo install -m 0644 ${HOST_CA_PEM} ${SYSTEM_TRUST_CERT}")
        cmds+=("sudo update-ca-certificates")
    ;; esac
    case " ${needs[*]} " in *" firefox "*)
        ff_json="{\"policies\":{\"Certificates\":{\"Install\":[\"${FIREFOX_POLICIES_CERT}\"]}}}"
        cmds+=("sudo install -d -m 0755 ${FIREFOX_POLICIES_DIR}")
        cmds+=("sudo install -m 0644 ${HOST_CA_PEM} ${FIREFOX_POLICIES_CERT}")
        cmds+=("printf '%s\\n' '${ff_json}' | sudo tee ${FIREFOX_POLICIES_FILE} >/dev/null")
        cmds+=("sudo chmod 0644 ${FIREFOX_POLICIES_FILE}")
    ;; esac

    print_sudo_recipe "${cmds[@]}"

    # Re-detect what's still needed.
    needs2=()
    if route_needs_update    "$VM_IP";          then needs2+=(route);    fi
    if resolver_needs_update;                    then needs2+=(resolver); fi
    if ! ca_in_systrust     "$HOST_CA_PEM";    then needs2+=(systrust); fi
    if firefox_policies_needs_update "$HOST_CA_PEM"; then needs2+=(firefox);  fi

    if [ ${#needs2[@]} -eq 0 ]; then
        ok "all operations already complete (you ran them manually)"
    else
        sudo -v || die "sudo authentication failed."
        case " ${needs2[*]} " in *" route "*)    apply_route        "$VM_IP"       ;; esac
        case " ${needs2[*]} " in *" resolver "*) apply_resolver                     ;; esac
        case " ${needs2[*]} " in *" systrust "*) apply_ca_to_systrust "$HOST_CA_PEM" ;; esac
        case " ${needs2[*]} " in *" firefox "*)  apply_firefox_policies "$HOST_CA_PEM" ;; esac
        sudo -k 2>/dev/null || true
        ok "host networking + trust applied"
    fi

    # Always record the trusted CA's fingerprint for uninstall to find.
    if ca_in_systrust "$HOST_CA_PEM"; then
        record_ca_fingerprint "$HOST_CA_PEM"
    fi
else
    ok "host already configured for ${VM_IP}; no sudo needed"
fi

# ============================================================
# Stage 5 — Create the VM
# ============================================================

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
echo "    Creating VM: name=${VM_NAME}  IP=${VM_IP}  user=${VM_USER}  memory=${VM_MEMORY_GB}GB  disk=${VM_DISK_SIZE}GB"
echo

bash "${SCRIPT_DIR}/create-vm.sh" \
    --octet="$VM_OCTET" \
    --user="$VM_USER" \
    --ssh-pub-key="$SSH_KEY" \
    --memory-gb="$VM_MEMORY_GB" \
    --disk-gb="$VM_DISK_SIZE" \
    --host-ca-pem="$HOST_CA_PEM" \
    --host-ca-key="$HOST_CA_KEY"

# ============================================================
# Stage 6 — Pre-warm demo stack
# ============================================================
# Best-effort: a failure here just means lazy provisioning later.

# The runtime container itself is created by `mpd --vm-setup` (stage 5).
step "Pre-warming demo database"
if ssh_cmd "$VM_IP" "$VM_USER" 'mpd --db-create=postgres:latest'; then
    ok "postgres:latest ready"
else
    warn "postgres:latest pre-warm failed; demo will provision on first run"
fi

# ============================================================
# Stage 7 — State refresh
# ============================================================

set_mpd_ssh_config    "$VM_NAME" "$VM_IP" "$VM_USER"
write_mpd_current_env "$VM_NAME" "$VM_IP" "$VM_USER"
ensure_desktop_shortcut

# ============================================================
# Done
# ============================================================

echo
echo "============================================="
echo "  Your mpd-vm is ready!"
echo "  Activities → 'mpd-vm' (or 'ssh mpd-vm')"
echo "============================================="
echo
