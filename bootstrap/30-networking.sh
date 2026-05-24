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
#   - NetworkManager owns the link
#   - systemd-resolved owns DNS (NM's `dns=systemd-resolved` plugin)
#   - libnss-resolve plugs glibc NSS into resolved
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

# --- NetworkManager → systemd-resolved DNS plugin --------------------

step "NetworkManager DNS plugin"

NM_DROP_IN=/etc/NetworkManager/conf.d/10-mpd-dns.conf
NM_BODY=$'[main]\ndns=systemd-resolved\n'
if [ -f "${NM_DROP_IN}" ] && [ "$(sudo cat "${NM_DROP_IN}" 2>/dev/null || true)" = "${NM_BODY}" ]; then
    ok "${NM_DROP_IN} already in place"
else
    sudo install -d -m 755 "$(dirname "${NM_DROP_IN}")"
    printf '%s' "${NM_BODY}" | sudo install -m 644 /dev/stdin "${NM_DROP_IN}"
    ok "wrote ${NM_DROP_IN}"
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

# Re-read NM drop-in and re-bind resolved.
sudo systemctl restart NetworkManager
sleep 1
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

    # Find the primary active NM connection.
    conn="$(nmcli -t -f NAME,STATE connection show --active 2>/dev/null \
              | awk -F: '$2=="activated"{print $1; exit}')"
    [ -n "${conn}" ] || die "no active NetworkManager connection found"

    iface="$(nmcli -t -f GENERAL.DEVICES connection show "${conn}" \
              | awk -F: '{print $2; exit}')"
    [ -n "${iface}" ] || die "could not derive interface for connection '${conn}'"

    cidr="$(ip -4 -o addr show dev "${iface}" 2>/dev/null \
              | awk '{print $4; exit}')"
    [ -n "${cidr}" ] || die "no IPv4 address on ${iface}"

    subnet24="$(echo "${cidr}" | cut -d/ -f1 | cut -d. -f1-3)"
    prefix="$(echo "${cidr}" | cut -d/ -f2)"
    gateway="$(ip -4 route 2>/dev/null | awk '/^default/ {print $3; exit}')"
    [ -n "${gateway}" ] || die "no default route found"

    new_ip="${subnet24}.${OCTET}"
    current_ip="$(echo "${cidr}" | cut -d/ -f1)"

    if [ "${current_ip}" = "${new_ip}" ] \
       && [ "$(nmcli -t -f ipv4.method connection show "${conn}" | cut -d: -f2)" = "manual" ]; then
        ok "static IP ${new_ip} already pinned on ${iface}"
        write_platform_env "managed" "${new_ip}"
    else
        # Point DNS at the gateway. In every NAT-style hypervisor network
        # we ship for (Parallels Shared, libvirt default, Hyper-V Default
        # Switch, VirtualBox NAT) the gateway runs a DNS proxy back to
        # the host resolver. Leaving ipv4.dns empty here makes NM push
        # zero upstream DNS into systemd-resolved when the connection
        # comes back up — `apt-get update` then fails with "Temporary
        # failure resolving" in bootstrap/40.
        sudo nmcli connection modify "${conn}" \
            ipv4.method   manual \
            ipv4.addresses "${new_ip}/${prefix}" \
            ipv4.gateway   "${gateway}" \
            ipv4.dns       "${gateway}" \
            ipv4.ignore-auto-dns yes

        # Write platform.env BEFORE the IP bounce — once nmcli up runs,
        # the SSH session dies and we may not get another foreground
        # opportunity to write it. We know the target IP ahead of time.
        write_platform_env "managed" "${new_ip}"

        # Print confirmation while we still have a live SSH stdout.
        ok "static IP being applied: ${new_ip}/${prefix} gw ${gateway} on ${iface}"
        warn "nmcli connection up backgrounded — SSH about to drop, this is expected"

        # Background the connection bounce so this script can exit
        # cleanly and the orchestrator's ssh returns immediately rather
        # than blocking on a stale TCP connection.
        #
        #   - nohup: ignore SIGHUP when sshd reaps the session
        #   - </dev/null + >/dev/null 2>&1: fully detach stdio
        #   - setsid: new session so kernel SIGHUP-on-session-leader-exit
        #     doesn't reach us
        #   - disown: remove from this shell's job table
        # Together these let nmcli run to completion under init after
        # this script and its ssh session are gone.
        setsid nohup bash -c "sudo nmcli connection up \"${conn}\"" \
            </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true

        # Exit immediately — anything after this would race the
        # disappearing SSH session. The orchestrator polls the new IP.
        exit 0
    fi
else
    ok "sandbox VM: leaving IP on DHCP"
    write_platform_env "sandbox" ""
fi
