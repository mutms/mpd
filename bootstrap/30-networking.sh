#!/bin/bash
# bootstrap/30-networking.sh
#
# Standardize the VM's network stack and fix the IP + hostname to the
# canonical form. Idempotent.
#
# Usage:
#   bash bootstrap/30-networking.sh <NNN>
#     <NNN>   3-digit octet:
#               000          sandbox  — rename hostname to mpd-000, leave
#                                       IP on DHCP.
#               100..254     managed  — rename hostname to mpd-<NNN>,
#                                       pin static IP <subnet>.<NNN>.
#
# Network stack target (Debian Trixie):
#   - link manager: systemd-networkd (one stack for every mpd VM —
#     Debian generic-cloud has it by default; Desktop templates must
#     be converted from NetworkManager during template prep).
#   - systemd-resolved owns DNS.
#   - libnss-resolve plugs glibc NSS into resolved.
# This matches what the in-VM `mpd --setup` asserts is in place.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/00-common.sh"

[ $# -eq 1 ] || die "Usage: bash 30-networking.sh <NNN>   (NNN = 000 or 100..254)"
OCTET="$1"

# --- Platform identity helper ---------------------------------------
# Write /var/lib/mpd/conf/platform.env with the dev user as owner of
# the conf dir. Called once from each branch (managed/sandbox/already-
# pinned) of the static-IP block below so the script can exit early
# in the "ssh-is-about-to-die" path without falling through to a
# bottom-of-script writer.
write_platform_env() {
    local kind="$1"  ip="$2"
    local conf_dir=/var/lib/mpd/conf
    sudo install -d -o "$(id -un)" -g "$(id -gn)" -m 0755 "${conf_dir}"
    cat > "${conf_dir}/platform.env" <<EOF
# mpd platform identity — written by bootstrap/30-networking.sh.
# Lives under /var/lib/mpd/conf/ (persistent identity dir for the in-VM mpd binary).
MPD_PLATFORM=${kind}
MPD_VM_IP=${ip}
MPD_VM_ID=$(printf '%03d' "${OCTET}")
EOF
    chmod 0644 "${conf_dir}/platform.env"
    ok "wrote ${conf_dir}/platform.env (platform=${kind}, vm_id=$(printf '%03d' "${OCTET}"))"
}

# Validate: 000 (sandbox) or 100..254 (managed). 001..099 is reserved
# (DHCP pool) and 255+ is out of range.
[[ "${OCTET}" =~ ^[0-9]+$ ]] || die "octet '${OCTET}' is not numeric"
if [ "${OCTET}" -gt 254 ] || \
   { [ "${OCTET}" -gt 0 ] && [ "${OCTET}" -lt 100 ]; }; then
    die "octet '${OCTET}' out of range. Allowed: 0 (sandbox) or 100..254 (managed)."
fi

# --- Link manager: detect, convert later if needed ------------------
# mpd standardizes on systemd-networkd inside the VM. Two starting
# states we handle automatically:
#   - **networkd already active** (Debian generic-cloud, UTM cidata
#     path): just normalize the static IP file.
#   - **NetworkManager active** (Debian Desktop, untouched Parallels
#     template): the static-IP block below will write our .network
#     file, then background a conversion (stop NM → enable networkd →
#     apt-purge NM → networkctl reconfigure). SSH drops during the
#     switch; the orchestrator polls the canonical IP.
# A fresh Debian Trixie install is guaranteed to be one or the other.

USING_NM=0
if command -v nmcli >/dev/null 2>&1 \
   && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    USING_NM=1
    ok "link manager: NetworkManager (will convert to systemd-networkd)"
elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    ok "link manager: systemd-networkd"
else
    die "neither NetworkManager nor systemd-networkd is active. Inspect: systemctl status NetworkManager systemd-networkd"
fi

# --- Disable IPv6 -----------------------------------------------------
# mpd is IPv4-only end-to-end (container subnet, dnsmasq's `*.mpd.test`
# zone, WireGuard tunnel). Leaving IPv6 enabled means happy-eyeballs
# AAAA queries leak to public DNS and stalls show up as multi-second
# `getaddrinfo` delays. Persisted via sysctl.d so the setting survives
# reboots. Idempotent: same content = no-op rewrite.

step "Disabling IPv6 (mpd is IPv4-only)"

IPV6_DROP_IN=/etc/sysctl.d/99-mpd-disable-ipv6.conf
IPV6_BODY="# mpd: IPv4-only end-to-end (container subnet, dnsmasq, WG tunnel).
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
"
if [ -f "${IPV6_DROP_IN}" ] && [ "$(sudo cat "${IPV6_DROP_IN}" 2>/dev/null || true)" = "${IPV6_BODY}" ]; then
    ok "${IPV6_DROP_IN} already in place"
else
    printf '%s' "${IPV6_BODY}" | sudo install -m 644 /dev/stdin "${IPV6_DROP_IN}"
    sudo sysctl --load="${IPV6_DROP_IN}" >/dev/null
    ok "wrote + applied ${IPV6_DROP_IN}"
fi

# --- Hostname canonicalization ---------------------------------------

step "Hostname"

target="mpd-$(printf '%03d' "${OCTET}")"
current="$(hostname -s)"

if [ "${current}" = "${target}" ]; then
    ok "hostname already ${target}"
else
    sudo hostnamectl set-hostname "${target}"
    # /etc/hosts 127.0.1.1 line — Debian convention. Add or replace.
    if grep -qE "^127\.0\.1\.1[[:space:]]" /etc/hosts; then
        sudo sed -i "s|^127\.0\.1\.1[[:space:]].*|127.0.1.1\t${target}|" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "${target}" | sudo tee -a /etc/hosts >/dev/null
    fi
    ok "hostname renamed: ${current} → ${target}"
fi

# --- systemd-resolved + libnss-resolve --------------------------------

step "systemd-resolved + libnss-resolve"

need_install=()
dpkg -s systemd-resolved >/dev/null 2>&1 || need_install+=(systemd-resolved)
dpkg -s libnss-resolve   >/dev/null 2>&1 || need_install+=(libnss-resolve)
if [ ${#need_install[@]} -gt 0 ]; then
    sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "${need_install[@]}"
    ok "installed: ${need_install[*]}"
else
    ok "systemd-resolved + libnss-resolve already installed"
fi

sudo systemctl enable --now systemd-resolved >/dev/null 2>&1 || true
systemctl is-active --quiet systemd-resolved \
    || die "systemd-resolved didn't come up. Inspect: systemctl status systemd-resolved"

# Re-bind systemd-resolved.
sudo systemctl restart systemd-resolved

# Wait for DNS to settle (up to 30 s).
dns_ok=0
for _ in $(seq 1 30); do
    if getent hosts deb.debian.org >/dev/null 2>&1; then
        dns_ok=1
        break
    fi
    sleep 1
done
[ "${dns_ok}" = 1 ] \
    || die "DNS via systemd-resolved did not come up within 30 s. Inspect: resolvectl status"
ok "DNS active (deb.debian.org resolves)"

# --- Static IP (only for managed octets in 100..254) -----------------

if [ "${OCTET}" -ge 100 ]; then
    step "Static IP for managed VM"

    iface="$(ip -4 -o route show default 2>/dev/null | awk '{print $5; exit}')"
    [ -n "${iface}" ] || die "no default IPv4 route — cannot derive interface"

    cidr="$(ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{print $4; exit}')"
    [ -n "${cidr}" ] || die "no IPv4 address on ${iface}"

    subnet24="$(echo "${cidr}" | cut -d/ -f1 | cut -d. -f1-3)"
    prefix="$(echo "${cidr}" | cut -d/ -f2)"
    gateway="$(ip -4 route 2>/dev/null | awk '/^default/ {print $3; exit}')"
    [ -n "${gateway}" ] || die "no default route found"

    new_ip="${subnet24}.${OCTET}"
    current_ip="$(echo "${cidr}" | cut -d/ -f1)"

    # Point DNS at the gateway. In every NAT-style hypervisor network
    # we ship for (Parallels Shared, vmnet shared bridge, libvirt
    # default, Hyper-V Default Switch, VirtualBox NAT) the gateway
    # runs a DNS proxy back to the host resolver. Leaving DNS empty
    # would make networkd push nothing to systemd-resolved and
    # `apt-get update` in bootstrap/40 would fail.
    #
    # `05-mpd.network` deliberately sorts before any cloud-init or
    # distro-shipped `10-*.network` so systemd-networkd matches ours
    # first (.network files don't merge — first hit wins).
    NETWORKD_FILE=/etc/systemd/network/05-mpd.network
    NETWORKD_BODY="# mpd: managed VM static IP. Written by bootstrap/30-networking.sh.
[Match]
Name=${iface}

[Network]
Address=${new_ip}/${prefix}
Gateway=${gateway}
DNS=${gateway}
"
    existing_body=""
    [ -f "${NETWORKD_FILE}" ] && existing_body="$(sudo cat "${NETWORKD_FILE}" 2>/dev/null || true)"

    # Ask networkd which .network file is currently governing this link.
    # Just checking "current_ip == canonical" isn't enough — a DHCP lease
    # could coincidentally hand out the canonical address. The
    # authoritative signal is networkd reporting our 05-mpd.network as
    # the active config (and the file content matching, in case someone
    # edited it after networkd loaded it).
    active_network_file=""
    if [ "$USING_NM" = 0 ]; then
        active_network_file="$(networkctl status "${iface}" 2>/dev/null \
            | awk -F': *' '/^[[:space:]]*Network File:/{print $2; exit}')"
    fi

    # Idempotent fast path: networkd is the link manager, networkd is
    # using *our* file (not cloud-init's or distro's), file content is
    # exactly what we'd write, and the IP we'd assign is already live.
    if [ "$USING_NM" = 0 ] \
       && [ "${active_network_file}" = "${NETWORKD_FILE}" ] \
       && [ "${existing_body}" = "${NETWORKD_BODY}" ] \
       && [ "${current_ip}" = "${new_ip}" ]; then
        ok "static IP ${new_ip} already pinned on ${iface} (governed by ${NETWORKD_FILE})"
        write_platform_env "managed" "${new_ip}"
    else
        # Write the canonical .network file + platform.env synchronously
        # so neither survives only in the about-to-be-killed SSH session.
        printf '%s' "${NETWORKD_BODY}" | sudo install -m 644 /dev/stdin "${NETWORKD_FILE}"
        ok "wrote ${NETWORKD_FILE}"
        write_platform_env "managed" "${new_ip}"
        ok "static IP being applied: ${new_ip}/${prefix} gw ${gateway} on ${iface}"

        # Build the apply sequence. Three things can each drop SSH:
        #   - swapping the link manager (NM → networkd)
        #   - changing the IP address on the active link
        #   - apt-purging network-manager (postrm tears down NM's connections)
        # Run the whole sequence in a backgrounded subshell so the SSH
        # session that invoked this script can return cleanly.
        APPLY=""
        if [ "$USING_NM" = 1 ]; then
            APPLY="$APPLY sudo systemctl enable --now systemd-networkd systemd-resolved >/dev/null;"
            APPLY="$APPLY sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf;"
            APPLY="$APPLY sudo systemctl disable --now NetworkManager >/dev/null 2>&1 || true;"
            APPLY="$APPLY sudo env DEBIAN_FRONTEND=noninteractive apt-get -y purge \
network-manager network-manager-gnome >/dev/null 2>&1 || true;"
        fi
        APPLY="$APPLY sudo networkctl reload;"
        APPLY="$APPLY sudo networkctl reconfigure ${iface};"

        # If nothing IP-disrupting is happening (already on networkd,
        # IP already correct, only the .network file got rewritten),
        # the reload is harmless — run it foreground.
        if [ "$USING_NM" = 0 ] && [ "${current_ip}" = "${new_ip}" ]; then
            eval "$APPLY"
            ok "networkctl reload (no IP or link-manager change)"
        else
            warn "applying network changes — SSH about to drop, this is expected"
            # Background the apply so this script can exit cleanly and
            # the orchestrator's ssh returns immediately rather than
            # blocking on a stale TCP connection.
            #
            #   - nohup: ignore SIGHUP when sshd reaps the session
            #   - </dev/null + >/dev/null 2>&1: fully detach stdio
            #   - setsid: new session so kernel SIGHUP-on-session-leader-exit
            #     doesn't reach us
            #   - disown: remove from this shell's job table
            setsid nohup bash -c "$APPLY" </dev/null >/dev/null 2>&1 &
            disown 2>/dev/null || true

            # Exit immediately — anything after this would race the
            # disappearing SSH session. The orchestrator polls the new IP.
            exit 0
        fi
    fi
else
    ok "sandbox VM: leaving IP on DHCP"
    write_platform_env "sandbox" ""
fi
