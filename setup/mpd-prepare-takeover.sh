#!/bin/bash
# setup/mpd-prepare-takeover.sh
#
# Prepares a fresh Debian Trixie install — desktop OR server — to be
# adopted by the host-side `mpd-virt` orchestrator. Run it ON THE VM, as
# your dev user (NOT root).
#
# It may take a few runs with reboots in between to converge the network
# stack (a GNOME desktop ships NetworkManager, which mpd replaces with
# systemd-networkd + systemd-resolved). When every check is green it
# prints the exact command to run on the Mac:
#
#     mpd-virt takeover <NNN> <IP>
#
# reading both the id (from the hostname) and the IP off the VM, so you
# never type either by hand.
#
# Wgettable / self-contained: it runs before the mpd repo is cloned, so
# it inlines its own helpers rather than sourcing bootstrap/00-common.sh.
#
#   bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/setup/mpd-prepare-takeover.sh)
#
# Idempotent — safe to re-run after a partial step or a reboot.
#
# Steps: (1) hostname gate mpd-<NNN>, (2) passwordless sudo, (3) convert
# the network stack to systemd-networkd + systemd-resolved (desktop:
# NetworkManager; server: ifupdown), (4) readiness check → prints the
# `mpd-virt takeover <NNN> <IP>` line. Step 3 asks for one reboot; the
# re-run finishes and prints the command.

set -euo pipefail

# --- Inline helpers (the mpd repo may not be cloned yet) --------------
step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# --- 1. Hostname must be mpd-<NNN> -----------------------------------
# The hostname is mpd's single source of truth: the id, zone, subnet and
# every name derive from it. Managed ids are 100..254 (000 is the
# sandbox; 001..099 is the hypervisor DHCP pool). You set this at install
# time; prep only validates it.
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
    die "id ${nnn} is out of range. Managed VMs are 100..254.
(000 is the sandbox — use mpd-sandbox-setup.sh; 001..099 is the DHCP pool.)"
fi
ok "hostname '${host}' (id ${nnn})"

# --- OS gate: Debian Trixie ------------------------------------------
step "Operating system"
[ -r /etc/os-release ] || die "/etc/os-release missing — cannot verify the OS."
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "debian" ] \
    || die "mpd targets Debian (got ID=${ID:-unknown})."
[ "${VERSION_CODENAME:-}" = "trixie" ] \
    || die "mpd targets Debian Trixie (got VERSION_CODENAME=${VERSION_CODENAME:-unknown})."
ok "Debian Trixie"

# --- 2. Passwordless sudo for the current (non-root) user ------------
# Takeover drives the VM over SSH as this user and never types a
# password, so `sudo -n` must be silent. Refuse root: the whole point is
# an unprivileged dev account that can escalate without a prompt.
step "Passwordless sudo for $(id -un)"
[ "$(id -u)" -ne 0 ] \
    || die "run this as your dev user, not root.
Takeover drives the VM as an unprivileged user over SSH; root has no
authorized key and no home for mpd to live in."

# Guard the probe with `command -v`: a minimal server has no sudo at all,
# and calling it would just print "command not found". Everything that
# needs root below goes through `su -` (root password), never sudo.
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    ok "already configured (sudo -n works)"
else
    user_name="$(id -un)"
    sudoers_path="/etc/sudoers.d/00-mpd-${user_name}"
    echo "    No passwordless sudo for ${user_name}. Asking for the root password"
    echo "    (one-time setup — installs sudo if a minimal install lacks it)."
    echo "    The prompt below comes from \`su\`."
    echo

    # `su - -c` runs one command as root in a login shell, so root's PATH
    # (with /usr/sbin) finds visudo/usermod. A minimal Debian server
    # install ships neither sudo nor /etc/sudoers.d, so install sudo
    # first; a desktop install already has both. Then make the dev user a
    # real sudoer (sudo group) and drop in a NOPASSWD rule. visudo -cf
    # validates the drop-in; an invalid file is removed rather than left
    # to brick sudo. install -m 0440 writes it with the mode sudoers wants.
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

    # No `sudo -n` re-check here: the su block already installed sudo,
    # wrote the drop-in, and validated it with `visudo -cf`. A re-run of
    # this script takes the fast path above and confirms it end to end.
    ok "passwordless sudo enabled for ${user_name}"
fi

# --- 3. Network stack: systemd-networkd + systemd-resolved -----------
# mpd standardizes on systemd-networkd for the link and systemd-resolved
# as the DNS sink (so `mpd --vm-setup` can inject the *.mpd.test
# resolver). A desktop ships NetworkManager, a server ships ifupdown;
# both are converted. We keep the DHCP address — the IP is never pinned
# here, it is read at the end and handed to takeover.
#
# The switch completes on a reboot: this run only DISABLES the old
# manager (so SSH/console survive), then asks for a reboot + re-run. The
# second run finds the stack already on networkd and prints the takeover
# line.

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

# 05- sorts ahead of any distro/cloud-init .network so networkd matches
# ours first. DHCP=yes: keep whatever address the hypervisor hands out.
printf '[Match]\nName=%s\n\n[Network]\nDHCP=yes\n' "${iface}" \
    | sudo tee /etc/systemd/network/05-mpd.network >/dev/null
sudo systemctl enable systemd-networkd >/dev/null 2>&1
ok "wrote 05-mpd.network (DHCP on ${iface}), enabled systemd-networkd"

# Hand the link off from whatever manages it now. DISABLE (not stop) so
# this session survives; the reboot below completes the switch.
reboot_needed=0
if systemctl is-active --quiet NetworkManager; then
    sudo systemctl disable NetworkManager >/dev/null 2>&1 || true
    reboot_needed=1
    ok "NetworkManager disabled (purged on the next run, once off the link)"
elif systemctl is-active --quiet networking && ! systemctl is-active --quiet systemd-networkd; then
    # ifupdown: comment out the iface's stanzas so its hotplug/ifup won't
    # fight networkd, then disable the service (networkd manages lo too).
    sudo sed -i -E "s/^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+${iface}([[:space:]].*)?$/# mpd-disabled: &/" \
        /etc/network/interfaces
    sudo systemctl disable networking >/dev/null 2>&1 || true
    reboot_needed=1
    ok "ifupdown neutralized for ${iface} (networking.service disabled)"
else
    ok "link already on systemd-networkd"
fi

# --- 4. Readiness + the takeover line --------------------------------
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
# Now that networkd feeds resolved real upstream servers, route glibc at
# the resolved stub (belt-and-suspenders with libnss-resolve).
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

# Off the old manager now — purge NetworkManager if it lingers (we're on
# networkd, so this can't drop the link).
if dpkg -s network-manager >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y purge network-manager network-manager-gnome >/dev/null 2>&1 || true
    ok "NetworkManager purged"
fi

vm_ip="$(ip -4 -o addr show "${iface}" | awk '{print $4}' | cut -d/ -f1 | head -1)"
echo
echo "================================================================"
echo "  ${host} is ready for takeover."
echo
echo "  On your Mac, run:"
echo "      mpd-virt takeover ${nnn} ${vm_ip}"
echo "================================================================"
