#!/bin/bash
# configure-client.sh — Configure host networking + trust to reach an mpd VM.
# Idempotent: safe to run multiple times.
#
# Steps:
#   1. Route to this VM's container subnet (10.163.<NNN>.0/24) via its IP.
#   2. systemd-resolved drop-in for *.<NNN>.mpd.test → dnsmasq inside it.
#   3. System trust bundle /usr/local/share/ca-certificates/mpd-test.crt
#      (curl, wget, etc.).
#   4. Firefox policies /etc/firefox/policies/policies.json (snap and apt
#      Firefox both honor it).
#   5. NSS DB at ~/.pki/nssdb (Chromium / Chrome / Edge).
#
# Privilege model: read-only inspection first; if anything needs to change,
# print the runnable `sudo` commands and let the dev choose between
# (a) running them in another terminal or (b) letting the script sudo.
# Re-detect after the prompt; apply only what's still needed; drop creds.
# CAs flow host → VM only — neither caroot/ nor ~/.mpd-virt/ca/ is ever
# populated from a VM source. If neither is populated, CA-related steps are
# skipped (route and resolver still applied).
#
# Called by setup.sh's existing-VM branches (re-verify / switch) and by
# start.sh (route is non-persistent across host reboots — re-asserted on
# every start).
#
# Usage:
#   bash lib/configure-client.sh --vm-ip=192.168.122.158 --vm-user=skodak [--skip-ca]

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

# This VM's subnet / zone / resolver drop-in — everything below is keyed
# on the VM id derived from VM_IP, so several VMs configure independently.
mpd_net_from_vm_ip "$VM_IP"

cleanup() {
    sudo -k 2>/dev/null || true
}
trap cleanup EXIT

# --- Phase 1a: locate host CA (host-only — never from a VM) ---

PLATFORM_CAROOT="${STATE_DIR}/ca"
PLATFORM_PEM="${PLATFORM_CAROOT}/rootCA.pem"
PLATFORM_KEY="${PLATFORM_CAROOT}/rootCA-key.pem"

cert_source=""
new_fp=""

if [ "$SKIP_CA" = 1 ]; then
    :
elif [ -f "$PLATFORM_PEM" ] && [ -f "$PLATFORM_KEY" ]; then
    cert_source="$PLATFORM_PEM"
else
    warn "no host CA found at ${PLATFORM_CAROOT}/ — skipping CA-related steps."
    warn "(run setup.sh to generate the host CA before configuring the client.)"
fi

if [ -n "$cert_source" ]; then
    new_fp=$(ca_fingerprint "$cert_source")
fi

# --- Phase 1b: detect what's needed (read-only) ---

needed=()
need_route=0
need_resolver=0
need_systrust=0
need_firefox=0
need_nssdb=0

detect_host_needs() {
    needed=()
    need_route=0; need_resolver=0; need_systrust=0; need_firefox=0; need_nssdb=0

    if route_needs_update "$VM_IP"; then
        need_route=1
        needed+=("install route ${CONTAINER_SUBNET_PREFIX} -> ${VM_IP}")
    fi

    if resolver_needs_update; then
        need_resolver=1
        needed+=("write ${RESOLVED_DROPIN_FILE} + reload systemd-resolved")
    fi

    if [ "$SKIP_CA" = 1 ] || [ -z "$cert_source" ]; then
        return 0
    fi

    if ! ca_in_systrust "$cert_source"; then
        need_systrust=1
        needed+=("install mpd CA into ${SYSTEM_TRUST_CERT}")
    fi

    if firefox_policies_needs_update "$cert_source"; then
        need_firefox=1
        needed+=("write ${FIREFOX_POLICIES_FILE} + cert at ${FIREFOX_POLICIES_CERT}")
    fi

    if ! ca_in_nssdb "$cert_source"; then
        need_nssdb=1
        needed+=("import mpd CA into ~/.pki/nssdb (Chromium / Chrome / Edge)")
    fi
}

detect_host_needs

# Snapshot Phase-1 state for Phase-3 reporting wording.
initial_need_route="$need_route"
initial_need_resolver="$need_resolver"
initial_need_systrust="$need_systrust"
initial_need_firefox="$need_firefox"
initial_need_nssdb="$need_nssdb"

# --- Phase 2a: NSS DB (user-level, no sudo) ---

if [ "$need_nssdb" = 1 ]; then
    apply_ca_to_nssdb "$cert_source"
    need_nssdb=0
fi

# --- Phase 2b: privileged ops (sudo recipe affordance) ---

# Build the printable recipe from current needs.
build_sudo_cmds() {
    cmds=()
    if [ "$need_route" = 1 ]; then
        cmds+=("sudo ip route replace ${CONTAINER_SUBNET_PREFIX} via ${VM_IP}")
    fi
    if [ "$need_resolver" = 1 ]; then
        cmds+=("sudo install -d -m 0755 ${RESOLVED_DROPIN_DIR}")
        cmds+=("printf '[Resolve]\\nDNS=${DNSMASQ_IP}\\nDomains=~${DNS_DOMAIN}\\n' | sudo tee ${RESOLVED_DROPIN_FILE} >/dev/null")
        cmds+=("sudo chmod 0644 ${RESOLVED_DROPIN_FILE}")
        cmds+=("sudo systemctl restart systemd-resolved")
    fi
    if [ "$need_systrust" = 1 ]; then
        cmds+=("sudo install -m 0644 ${cert_source} ${SYSTEM_TRUST_CERT}")
        cmds+=("sudo update-ca-certificates")
    fi
    if [ "$need_firefox" = 1 ]; then
        ff_json="{\"policies\":{\"Certificates\":{\"Install\":[\"${FIREFOX_POLICIES_CERT}\"]}}}"
        cmds+=("sudo install -d -m 0755 ${FIREFOX_POLICIES_DIR}")
        cmds+=("sudo install -m 0644 ${cert_source} ${FIREFOX_POLICIES_CERT}")
        cmds+=("printf '%s\\n' '${ff_json}' | sudo tee ${FIREFOX_POLICIES_FILE} >/dev/null")
        cmds+=("sudo chmod 0644 ${FIREFOX_POLICIES_FILE}")
    fi
}

# Are any of the privileged needs set?
any_priv_needed() {
    [ "$need_route" = 1 ] || [ "$need_resolver" = 1 ] \
        || [ "$need_systrust" = 1 ] || [ "$need_firefox" = 1 ]
}

if any_priv_needed; then
    build_sudo_cmds
    print_sudo_recipe "${cmds[@]}"

    # Re-detect — has the dev applied any of these in another terminal?
    detect_host_needs

    if ! any_priv_needed; then
        ok "all privileged operations already applied (you ran the recipe manually)"
    else
        sudo -v || die "sudo authentication failed."

        if [ "$need_route" = 1 ]; then
            apply_route "$VM_IP"
        fi
        if [ "$need_resolver" = 1 ]; then
            apply_resolver
        fi
        if [ "$need_systrust" = 1 ]; then
            apply_ca_to_systrust "$cert_source"
        fi
        if [ "$need_firefox" = 1 ]; then
            apply_firefox_policies "$cert_source"
        fi

        sudo -k 2>/dev/null || true
    fi

    # Always record the trusted CA's fingerprint (post-apply) so uninstall.sh
    # can find and remove this exact cert later.
    if [ -n "$cert_source" ] && ca_in_systrust "$cert_source"; then
        record_ca_fingerprint "$cert_source"
    fi
fi

# --- Phase 3: report (use snapshotted Phase-1 state for accurate wording) ---

step "Route ${CONTAINER_SUBNET_PREFIX} via ${VM_IP}"
if [ "$initial_need_route" = 1 ]; then
    ok "route added: ${CONTAINER_SUBNET_PREFIX} -> ${VM_IP}"
else
    ok "route already correct"
fi

step "DNS resolver ${RESOLVED_DROPIN_FILE} -> ${DNSMASQ_IP}"
if [ "$initial_need_resolver" = 1 ]; then
    ok "resolver written"
else
    ok "resolver already correct"
fi

if [ "$SKIP_CA" = 1 ]; then
    ok "skipping CA import (--skip-ca)"
elif [ -n "$cert_source" ]; then
    fp_lc=$(echo "$new_fp" | tr 'A-F' 'a-f')

    step "System trust ${SYSTEM_TRUST_CERT}"
    if [ "$initial_need_systrust" = 1 ]; then
        ok "CA cert installed (sha1 ${fp_lc})"
    else
        ok "CA cert already trusted (sha1 ${fp_lc})"
    fi

    step "Firefox policies ${FIREFOX_POLICIES_FILE}"
    if [ "$initial_need_firefox" = 1 ]; then
        ok "policies.json written"
    else
        ok "policies.json already correct"
    fi

    step "Chromium NSS DB ~/.pki/nssdb"
    if [ "$initial_need_nssdb" = 1 ]; then
        ok "CA imported (sha1 ${fp_lc})"
    else
        ok "CA already in NSS DB (sha1 ${fp_lc})"
    fi
fi

echo
echo "    Linux client configured. Open https://${DNS_DOMAIN} in Firefox or Chromium."
