#!/bin/bash
# configure-client.sh — Configure macOS networking to reach an mpd-machine VM.
# Idempotent: safe to run multiple times.
#
# Steps:
#   1. Add a route so macOS reaches the container subnet (10.163.0.0/24)
#      through the VM.
#   2. Add /etc/resolver/mpd.test so macOS resolves *.mpd.test via dnsmasq
#      inside the VM.
#   3. Import the mpd CA certificate into /Library/Keychains/System.keychain
#      so browsers trust *.mpd.test HTTPS without warnings. CA source: the
#      local cache at ~/Developer/mpd/conf/caroot/rootCA.pem if present
#      (shared with mpd-desktop), otherwise scp from the VM.
#
# Privilege model: the script first inspects current state without sudo.
# If anything needs to change (route missing, resolver missing, CA not
# trusted yet), it asks for sudo with a one-time explanation of which
# operations need it. If the host is already in the desired state, no
# sudo prompt happens at all.
#
# Called by lib/setup.sh after VM creation or when switching VMs, and by
# lib/start.sh (route is not persistent across reboot — re-asserted on
# every start).
#
# Usage:
#   bash lib/configure-client.sh --vm-ip=192.168.64.158 --vm-user=skodak [--skip-ca]

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

# Always drop cached sudo credentials when this script exits (success, error,
# or early termination) so a later bug can't accidentally piggy-back on the
# elevated session — the next sudo, if any, would re-prompt.
cleanup() {
    [ -n "${tmp_cert:-}" ] && rm -f "$tmp_cert"
    sudo -k 2>/dev/null || true
}
trap cleanup EXIT

# --- Phase 1: detect what's needed (read-only, no sudo) ---

needed=()
need_route=0
need_resolver=0
need_ca=0
cert_source=""
new_fp=""
tmp_cert=""

# Route
route_out=$(route -n get -inet "$CONTAINER_PROBE_IP" 2>/dev/null || true)
route_dest=$(awk '/destination:/ { print $2; exit }' <<<"$route_out")
route_gw=$(awk '/gateway:/    { print $2; exit }' <<<"$route_out")
if [[ "$route_dest" == 10.163.0* ]] && [ "$route_gw" = "$VM_IP" ]; then
    :
else
    need_route=1
    needed+=("install route ${CONTAINER_SUBNET_PREFIX} -> ${VM_IP}")
fi

# Resolver
resolver_path="/etc/resolver/${DNS_DOMAIN}"
desired_resolver="nameserver ${DNSMASQ_IP}"
if [ -f "$resolver_path" ] && [ "$(cat "$resolver_path" 2>/dev/null)" = "$desired_resolver" ]; then
    :
else
    need_resolver=1
    needed+=("write /etc/resolver/${DNS_DOMAIN}")
fi

# CA — pick a source we can read without elevation
HOST_CA_PEM="${HOME}/Developer/mpd/conf/caroot/rootCA.pem"
if [ "$SKIP_CA" = 1 ]; then
    :
elif [ -f "$HOST_CA_PEM" ]; then
    cert_source="$HOST_CA_PEM"
else
    # No local copy — fetch from VM into a tmp file. scp doesn't need sudo.
    tmp_cert=$(mktemp)
    if scp -q -o StrictHostKeyChecking=no -o BatchMode=yes \
            "${VM_USER}@${VM_IP}:${CA_CERT_REMOTE_PATH}" "$tmp_cert" 2>/dev/null; then
        cert_source="$tmp_cert"
    else
        rm -f "$tmp_cert"
        tmp_cert=""
        warn "Could not fetch CA cert from ${VM_USER}@${VM_IP} — skipping CA check."
    fi
fi

if [ -n "$cert_source" ]; then
    new_fp=$(openssl x509 -fingerprint -sha1 -noout -in "$cert_source" 2>/dev/null \
                | awk -F= '{ print $2 }' | tr -d ':' | tr 'a-f' 'A-F')
    if [ -n "$new_fp" ]; then
        if security find-certificate -a -Z "$SYSTEM_KEYCHAIN" 2>/dev/null \
                | grep -q "^SHA-1 hash: ${new_fp}$"; then
            :
        else
            need_ca=1
            needed+=("import mpd CA into System keychain")
        fi
    fi
fi

# --- Phase 2: privileged operations (single fenced block) ---
# All `sudo` calls live here and only here. Cached creds are dropped at the
# end of the block so the non-privileged work that follows can't accidentally
# piggy-back on the elevated session. The EXIT trap is a belt-and-suspenders
# backstop; this explicit drop is the primary fence.

if [ ${#needed[@]} -gt 0 ]; then
    echo
    echo "macOS will ask for your password to:"
    for action in "${needed[@]}"; do
        echo "    - $action"
    done
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

# --- Phase 3: report + non-privileged state writes (no sudo from here on) ---

step "Route ${CONTAINER_SUBNET_PREFIX} via ${VM_IP}"
if [ "$need_route" = 1 ]; then
    if [[ "$route_dest" == 10.163.0* ]] && [ -n "$route_gw" ]; then
        echo "    replaced stale route (was via ${route_gw})"
    fi
    ok "route added: ${CONTAINER_SUBNET_PREFIX} -> ${VM_IP}"
else
    ok "route already correct"
fi

step "DNS resolver /etc/resolver/${DNS_DOMAIN} -> ${DNSMASQ_IP}"
if [ "$need_resolver" = 1 ]; then
    ok "resolver written"
else
    ok "resolver already correct"
fi

if [ "$SKIP_CA" = 1 ]; then
    ok "skipping CA import (--skip-ca)"
elif [ -n "$cert_source" ]; then
    step "mpd CA certificate"
    fp_lc=$(echo "$new_fp" | tr 'A-F' 'a-f')
    if [ "$need_ca" = 1 ]; then
        ok "CA cert imported (sha1 ${fp_lc})"
    else
        ok "CA cert already trusted (sha1 ${fp_lc})"
    fi
    # Record the SHA-1 so uninstall.sh can remove this exact cert without
    # guessing at the subject string.
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$new_fp" > "$STATE_CA_FILE"
fi

echo
echo "    macOS client configured. Open https://mpd.test to reach the portal."
# tmp_cert removal handled by EXIT trap above.
