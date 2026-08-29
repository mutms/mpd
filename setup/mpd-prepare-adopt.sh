#!/bin/bash
# setup/mpd-prepare-adopt.sh
#
# Prepare a fresh Debian Trixie install — desktop or server — for
# adoption by the host-side `mpd-virt` orchestrator. Run it ON THE VM,
# as your dev user (not root). It needs the hostname set to mpd-<NNN>
# and asks for the root password once. Converting the network stack
# takes one reboot; re-run after it. When every check is green it
# prints the `mpd-virt adopt` command to run on the host.
# Self-contained: runs before the mpd repo is cloned.
# Idempotent — safe to re-run after a partial step or a reboot.
#
#   bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/setup/mpd-prepare-adopt.sh)

set -euo pipefail

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
warn() { printf '    warn: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# The hostname is mpd's source of identity; prep only validates it.
step "Hostname"
host="$(hostname -s 2>/dev/null || cut -d. -f1 /etc/hostname | tr -d '[:space:]')"
case "${host}" in
    mpd-[0-9][0-9][0-9]) ;;
    *) die "hostname is '${host}', must be mpd-<NNN> (3-digit), e.g. mpd-137.
Set it and reboot:
    sudo hostnamectl set-hostname mpd-137" ;;
esac
nnn="${host#mpd-}"
id10="$((10#${nnn}))"    # force base-10 so a leading zero isn't read as octal
if [ "${id10}" -lt 100 ] || [ "${id10}" -gt 254 ]; then
    die "id ${nnn} is out of range. Managed VMs are 100..254 (001..099 is the DHCP pool)."
fi
ok "hostname '${host}' (id ${nnn})"

step "Operating system"
[ -r /etc/os-release ] || die "/etc/os-release missing — cannot verify the OS."
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "debian" ] \
    || die "mpd targets Debian (got ID=${ID:-unknown})."
[ "${VERSION_CODENAME:-}" = "trixie" ] \
    || die "mpd targets Debian Trixie (got VERSION_CODENAME=${VERSION_CODENAME:-unknown})."
ok "Debian Trixie"

# Adoption drives the VM over SSH as this user and never types a
# password, so `sudo -n` must be silent.
step "Passwordless sudo for $(id -un)"
[ "$(id -u)" -ne 0 ] \
    || die "run this as your dev user, not root.
Adoption drives the VM as an unprivileged user over SSH; root has no
authorized key and no home for mpd to live in."

# A minimal server install has no sudo; probe only when the command exists.
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    ok "already configured (sudo -n works)"
else
    user_name="$(id -un)"
    sudoers_path="/etc/sudoers.d/00-mpd-${user_name}"
    echo "    No passwordless sudo for ${user_name}. Asking for the root password"
    echo "    (one-time setup — installs sudo if a minimal install lacks it)."
    echo "    The prompt below comes from \`su\`."
    echo

    # `su - -c` runs the command as root with root's PATH, where visudo
    # and usermod live. visudo -cf validates the drop-in; an invalid
    # file is removed so sudo is not bricked.
    if ! su - -c "
        set -e
        if ! command -v sudo >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq sudo
        fi
        install -d -m 0755 /etc/sudoers.d
        usermod -aG sudo '${user_name}'
        install -m 0440 -o root -g root /dev/null '${sudoers_path}'
        printf '%s ALL=(ALL) NOPASSWD:ALL\n' '${user_name}' > '${sudoers_path}'
        if ! visudo -cf '${sudoers_path}' >/dev/null; then
            rm -f '${sudoers_path}'
            echo 'visudo rejected the drop-in; removed.' >&2
            exit 1
        fi
    "; then
        die "Failed to configure sudo for '${user_name}'. Wrong root password, the
user isn't permitted to become root via su, or sudo couldn't be installed."
    fi

    # No re-check: the su block validated the drop-in with visudo -cf.
    ok "passwordless sudo enabled for ${user_name}"
fi

# mpd standardizes on systemd-networkd + systemd-resolved; both
# NetworkManager (desktop) and ifupdown (server) are converted. The DHCP
# address is kept. The old manager is only DISABLED, so SSH and the
# console survive; the reboot completes the switch and a re-run finishes.

step "IPv6 off + IPv4 forwarding"
printf 'net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.lo.disable_ipv6 = 1\n' \
    | sudo tee /etc/sysctl.d/99-mpd-disable-ipv6.conf >/dev/null
printf 'net.ipv4.ip_forward = 1\n' \
    | sudo tee /etc/sysctl.d/99-mpd-forwarding.conf >/dev/null
sudo sysctl --system >/dev/null 2>&1 || true
ok "IPv6 disabled, IPv4 forwarding enabled"

step "systemd-resolved + libnss-resolve"
need=()
dpkg -s systemd-resolved >/dev/null 2>&1 || need+=(systemd-resolved)
dpkg -s libnss-resolve   >/dev/null 2>&1 || need+=(libnss-resolve)
if [ "${#need[@]}" -gt 0 ]; then
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}"
    ok "installed: ${need[*]}"
else
    ok "already installed"
fi
sudo systemctl enable systemd-resolved >/dev/null 2>&1 || true

step "Link manager → systemd-networkd (DHCP)"
iface="$(ip -4 -o route show default | awk '{print $5; exit}')"
[ -n "${iface}" ] || die "no default IPv4 route — cannot find the primary interface."

# 05- sorts ahead of any distro/cloud-init .network, so networkd matches
# this file first.
printf '[Match]\nName=%s\n\n[Network]\nDHCP=yes\n' "${iface}" \
    | sudo tee /etc/systemd/network/05-mpd.network >/dev/null
sudo systemctl enable systemd-networkd >/dev/null 2>&1
ok "wrote 05-mpd.network (DHCP on ${iface}), enabled systemd-networkd"

reboot_needed=0
if systemctl is-active --quiet NetworkManager; then
    sudo systemctl disable NetworkManager >/dev/null 2>&1 || true
    reboot_needed=1
    ok "NetworkManager disabled (purged on the next run, once off the link)"
elif systemctl is-active --quiet networking && ! systemctl is-active --quiet systemd-networkd; then
    # Comment out the iface's stanzas so hotplug/ifup cannot fight
    # networkd; networkd manages lo too, so the service can go.
    sudo sed -i -E "s/^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+${iface}([[:space:]].*)?$/# mpd-disabled: &/" \
        /etc/network/interfaces
    sudo systemctl disable networking >/dev/null 2>&1 || true
    reboot_needed=1
    ok "ifupdown neutralized for ${iface} (networking.service disabled)"
else
    ok "link already on systemd-networkd"
fi

if [ "${reboot_needed}" = 1 ]; then
    echo
    echo "================================================================"
    echo "  Network stack reconfigured. REBOOT, then re-run this script:"
    echo
    echo "      sudo reboot"
    echo "================================================================"
    exit 0
fi

step "Readiness"
sudo systemctl start systemd-resolved >/dev/null 2>&1 || true
# Route glibc at the resolved stub (belt-and-suspenders with libnss-resolve).
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
resolved_ok=0; systemctl is-active --quiet systemd-resolved && resolved_ok=1
networkd_ok=0; systemctl is-active --quiet systemd-networkd && networkd_ok=1
dns_ok=0
for _ in $(seq 1 15); do
    getent hosts deb.debian.org >/dev/null 2>&1 && { dns_ok=1; break; }
    sleep 1
done

if [ "${resolved_ok}" != 1 ] || [ "${networkd_ok}" != 1 ] || [ "${dns_ok}" != 1 ]; then
    die "not ready: resolved=${resolved_ok} networkd=${networkd_ok} dns=${dns_ok}.
If you just reconfigured the stack, reboot and re-run. Otherwise inspect:
    systemctl status systemd-resolved systemd-networkd
    resolvectl status"
fi
ok "systemd-resolved active, systemd-networkd managing ${iface}, DNS resolves"

# Purge a lingering NetworkManager; the link is on networkd, so this
# cannot drop it.
if dpkg -s network-manager >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y purge network-manager network-manager-gnome >/dev/null 2>&1 || true
    ok "NetworkManager purged"
fi

# avahi-daemon advertises <host>.local, which is how `mpd-virt adopt`
# finds this VM without an IP; adoption needs the name before mpd is
# installed, so the package comes here, not from `mpd --vm-setup`.
# openssh-server: a desktop install ships without sshd, and adoption
# drives the VM over SSH.
step "Guest integration (openssh-server, avahi-daemon, qemu-guest-agent)"
need=()
dpkg -s openssh-server   >/dev/null 2>&1 || need+=(openssh-server)
dpkg -s avahi-daemon     >/dev/null 2>&1 || need+=(avahi-daemon)
dpkg -s qemu-guest-agent >/dev/null 2>&1 || need+=(qemu-guest-agent)
if [ "${#need[@]}" -gt 0 ]; then
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}"
    ok "installed: ${need[*]}"
else
    ok "already installed"
fi
sudo systemctl enable --now ssh >/dev/null 2>&1 || true
if sudo systemctl enable --now avahi-daemon >/dev/null 2>&1; then
    ok "avahi-daemon active (${host}.local over mDNS)"
else
    warn "avahi-daemon could not be enabled — pass the IP to adopt explicitly"
fi
# Gate on the device: starting without it blocks forever; see
# docs/debugging.md "systemctl start qemu-guest-agent blocks forever".
if [ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]; then
    sudo systemctl start qemu-guest-agent >/dev/null 2>&1 \
        && ok "qemu-guest-agent running" \
        || warn "qemu-guest-agent did not start"
else
    ok "qemu-guest-agent installed (idle — no hypervisor device on this VM)"
fi

vm_ip="$(ip -4 -o addr show "${iface}" | awk '{print $4}' | cut -d/ -f1 | head -1)"
echo
echo "================================================================"
echo "  ${host} is ready for adoption."
echo
echo "  On your Mac, run (--backend = where the VM runs:"
echo "  generic | parallels | container | utm | proxmox):"
echo
echo "      mpd-virt adopt ${nnn} --backend=<backend>"
echo
echo "  The VM advertises itself over mDNS; if that doesn't reach"
echo "  your Mac, give the IP explicitly:"
echo
echo "      mpd-virt adopt ${nnn} ${vm_ip} --backend=<backend>"
echo "================================================================"
