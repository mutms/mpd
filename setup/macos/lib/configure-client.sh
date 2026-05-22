#!/bin/bash
# configure-client.sh — Configure macOS networking to reach an mpd-vm VM.
# Idempotent: safe to run multiple times.
#
# Steps:
#   1. Add a route so macOS reaches the container subnet (10.163.0.0/24)
#      through the VM.
#   2. Add /etc/resolver/mpd.test so macOS resolves *.mpd.test via dnsmasq
#      inside the VM.
#   3. Import the mpd CA certificate into /Library/Keychains/System.keychain
#      so browsers trust *.mpd.test HTTPS without warnings. CA source: the
#      local cache at ~/.mpd-virt/conf/caroot/rootCA.pem if present
#      (shared with mpd-desktop and macos), otherwise ~/.mpd-virt/ca/.
#
# Privilege model: inspect current state without sudo first, print a
# runnable recipe for any work needed, let the dev choose between running
# it themselves vs. letting the script sudo. If everything is already in
# the desired state, no sudo prompt happens at all.
#
# Called by lib/setup.sh after VM creation or when switching VMs, and
# by lib/doctor.sh (route is not persistent across host reboots; doctor
# re-asserts it).
#
# Usage:
#   bash lib/configure-client.sh --vm-ip=10.211.55.155 --vm-user=skodak [--skip-ca]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

VM_IP=""
VM_USER=""
SKIP_CA=0

for arg in "$@"; do
    case "$arg" in
        --vm-ip=*)   VM_IP="${arg#*=}" ;;
        --vm-user=*) VM_USER="${arg#*=}" ;;
        --skip-ca)   SKIP_CA=1 ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

[ -n "$VM_IP" ]   || die "Missing --vm-ip"
[ -n "$VM_USER" ] || die "Missing --vm-user"

cleanup() {
    sudo -k 2>/dev/null || true
}
trap cleanup EXIT

# --- Phase 1a: locate the host CA ---

resolver_path="/etc/resolver/${DNS_DOMAIN}"
desired_resolver="nameserver ${DNSMASQ_IP}"

CAROOT_DIR="${HOME}/.mpd-virt/conf/caroot"
CAROOT_PEM="${CAROOT_DIR}/rootCA.pem"
CAROOT_KEY="${CAROOT_DIR}/rootCA-key.pem"
PLATFORM_CAROOT="${STATE_DIR}/ca"
PLATFORM_PEM="${PLATFORM_CAROOT}/rootCA.pem"
PLATFORM_KEY="${PLATFORM_CAROOT}/rootCA-key.pem"

cert_source=""
new_fp=""

if [ "$SKIP_CA" = 1 ]; then
    :
elif [ -f "$CAROOT_PEM" ] && [ -f "$CAROOT_KEY" ]; then
    cert_source="$CAROOT_PEM"
    if [ ! -f "$PLATFORM_PEM" ] || [ ! -f "$PLATFORM_KEY" ]; then
        copy_ca_files "$CAROOT_PEM" "$CAROOT_KEY" "$PLATFORM_CAROOT"
    fi
elif [ -f "$PLATFORM_PEM" ] && [ -f "$PLATFORM_KEY" ]; then
    cert_source="$PLATFORM_PEM"
    if [ -d "${HOME}/.mpd-virt/conf" ] \
       && { [ ! -f "$CAROOT_PEM" ] || [ ! -f "$CAROOT_KEY" ]; }; then
        copy_ca_files "$PLATFORM_PEM" "$PLATFORM_KEY" "$CAROOT_DIR"
    fi
else
    warn "no host CA found at ${CAROOT_DIR}/ or ${PLATFORM_CAROOT}/ — skipping CA import."
    warn "(host CAs are never pulled from a VM; copy rootCA.pem+rootCA-key.pem into either location and re-run.)"
fi

if [ -n "$cert_source" ]; then
    new_fp=$(openssl x509 -fingerprint -sha1 -noout -in "$cert_source" 2>/dev/null \
                | awk -F= '{ print $2 }' | tr -d ':' | tr 'a-f' 'A-F')
fi

# --- Phase 1b: detect what host config is needed ---

needed=()
need_route=0
need_resolver=0
need_ca=0
route_dest=""
route_gw=""

detect_host_needs() {
    needed=()
    need_route=0
    need_resolver=0
    need_ca=0

    local route_out
    route_out=$(route -n get -inet "$CONTAINER_PROBE_IP" 2>/dev/null || true)
    route_dest=$(awk '/destination:/ { print $2; exit }' <<<"$route_out")
    route_gw=$(awk   '/gateway:/    { print $2; exit }' <<<"$route_out")
    if [[ "$route_dest" == 10.163.0* ]] && [ "$route_gw" = "$VM_IP" ]; then
        :
    else
        need_route=1
        needed+=("install route ${CONTAINER_SUBNET_PREFIX} -> ${VM_IP}")
    fi

    if [ -f "$resolver_path" ] && [ "$(cat "$resolver_path" 2>/dev/null)" = "$desired_resolver" ]; then
        :
    else
        need_resolver=1
        needed+=("write ${resolver_path}")
    fi

    if [ -n "$new_fp" ]; then
        if security find-certificate -a -Z "$SYSTEM_KEYCHAIN" 2>/dev/null \
                | grep -q "^SHA-1 hash: ${new_fp}$"; then
            :
        else
            need_ca=1
            needed+=("import mpd CA into System keychain")
        fi
    fi
}

detect_host_needs

initial_need_route="$need_route"
initial_need_resolver="$need_resolver"
initial_need_ca="$need_ca"
initial_route_dest="$route_dest"
initial_route_gw="$route_gw"

# --- Phase 2: privileged operations (sudo recipe affordance) ---

if [ ${#needed[@]} -gt 0 ]; then
    cmds=()
    if [ "$need_route" = 1 ]; then
        if [[ "$route_dest" == 10.163.0* ]] && [ -n "$route_gw" ]; then
            cmds+=("sudo route -n delete -net ${CONTAINER_SUBNET_PREFIX}")
        fi
        cmds+=("sudo route -n add -net ${CONTAINER_SUBNET_PREFIX} ${VM_IP}")
    fi
    if [ "$need_resolver" = 1 ]; then
        cmds+=("sudo mkdir -p /etc/resolver")
        cmds+=("printf 'nameserver ${DNSMASQ_IP}\\n' | sudo tee ${resolver_path} >/dev/null")
        cmds+=("sudo chmod 0644 ${resolver_path}")
    fi
    if [ "$need_ca" = 1 ]; then
        cmds+=("sudo security add-trusted-cert -d -r trustRoot -k ${SYSTEM_KEYCHAIN} \"${cert_source}\"")
    fi

    print_sudo_recipe "${cmds[@]}"

    detect_host_needs

    if [ ${#needed[@]} -eq 0 ]; then
        ok "host configuration already complete (you ran the recipe manually)"
    else
        sudo -v || die "sudo authentication failed."

        if [ "$need_route" = 1 ]; then
            if [[ "$route_dest" == 10.163.0* ]] && [ -n "$route_gw" ]; then
                sudo route -n delete -net "$CONTAINER_SUBNET_PREFIX" >/dev/null 2>&1 || true
            fi
            sudo route -n add -net "$CONTAINER_SUBNET_PREFIX" "$VM_IP" >/dev/null
        fi
        if [ "$need_resolver" = 1 ]; then
            sudo mkdir -p /etc/resolver
            printf '%s\n' "$desired_resolver" | sudo tee "$resolver_path" >/dev/null
            sudo chmod 0644 "$resolver_path"
        fi
        if [ "$need_ca" = 1 ]; then
            sudo security add-trusted-cert -d -r trustRoot -k "$SYSTEM_KEYCHAIN" "$cert_source"
        fi

        sudo -k 2>/dev/null || true
    fi
fi

# --- Phase 3: report + non-privileged state writes ---

step "Route ${CONTAINER_SUBNET_PREFIX} via ${VM_IP}"
if [ "$initial_need_route" = 1 ]; then
    if [[ "$initial_route_dest" == 10.163.0* ]] \
       && [ -n "$initial_route_gw" ] \
       && [ "$initial_route_gw" != "$VM_IP" ]; then
        echo "    replaced stale route (was via ${initial_route_gw})"
    fi
    ok "route added: ${CONTAINER_SUBNET_PREFIX} -> ${VM_IP}"
else
    ok "route already correct"
fi

step "DNS resolver /etc/resolver/${DNS_DOMAIN} -> ${DNSMASQ_IP}"
if [ "$initial_need_resolver" = 1 ]; then
    ok "resolver written"
else
    ok "resolver already correct"
fi

if [ "$SKIP_CA" = 1 ]; then
    ok "skipping CA import (--skip-ca)"
elif [ -n "$cert_source" ]; then
    step "mpd CA certificate"
    fp_lc=$(echo "$new_fp" | tr 'A-F' 'a-f')
    if [ "$initial_need_ca" = 1 ]; then
        ok "CA cert imported (sha1 ${fp_lc})"
    else
        ok "CA cert already trusted (sha1 ${fp_lc})"
    fi
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$new_fp" > "$STATE_CA_FILE"
fi

echo
echo "    macOS client configured. Open https://mpd.test to reach the portal."
