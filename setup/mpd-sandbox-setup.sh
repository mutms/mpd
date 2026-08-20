#!/bin/bash
# setup/mpd-sandbox-setup.sh
#
# Turn a fresh Debian Trixie install into a self-contained mpd SANDBOX:
# mpd built in place, its OWN self-signed CA generated in the VM (not
# pushed from a Mac), the whole platform brought up, and a demo site you
# can create in one command. You live in the VM (or reach it over an SSH
# SOCKS proxy from your host browser).
#
# Same first half as mpd-prepare-adopt.sh (hostname mpd-<NNN>, sudo,
# network stack → systemd-networkd + systemd-resolved). The difference is
# the second half: here we install mpd and run `mpd --vm-setup` IN the VM,
# so the CA is generated locally. Because the hostname is a real
# mpd-<NNN>, this same VM can later be adopted as a managed VM with
# `mpd-virt adopt <NNN> <IP>` from a Mac — that re-roots the certs to
# the Mac's CA; your projects survive.
#
# Run it ON THE VM, as your dev user (NOT root). Step 3 asks for one
# reboot; re-run to finish.
#
#   bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/setup/mpd-sandbox-setup.sh)
#
# Idempotent — safe to re-run after a partial step or a reboot.
#
# WARNING: a sandbox deliberately weakens VM security (passwordless sudo,
# a self-signed CA in the system trust store, persistent host keys). Only
# on a wipe-and-rebuild VM. Snapshot first.

set -euo pipefail

BOOTSTRAP_URL="https://raw.githubusercontent.com/mutms/mpd/main/bootstrap"

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
warn() { printf '    warn: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# --- 1. Hostname must be mpd-<NNN> (same gate as adoption prep) -------
step "Hostname"
host="$(hostname -s 2>/dev/null || cut -d. -f1 /etc/hostname | tr -d '[:space:]')"
case "${host}" in
    mpd-[0-9][0-9][0-9]) ;;
    *) die "hostname is '${host}', must be mpd-<NNN> (3-digit), e.g. mpd-137.
Set it and reboot:  sudo hostnamectl set-hostname mpd-137" ;;
esac
nnn="${host#mpd-}"
id10="$((10#${nnn}))"
if [ "${id10}" -lt 100 ] || [ "${id10}" -gt 254 ]; then
    die "id ${nnn} out of range. Managed/sandbox VMs are 100..254 (001..099 is the DHCP pool)."
fi
ok "hostname '${host}' (id ${nnn})"

step "Operating system"
[ -r /etc/os-release ] || die "/etc/os-release missing."
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "debian" ] && [ "${VERSION_CODENAME:-}" = "trixie" ] \
    || die "mpd targets Debian Trixie (got ID=${ID:-?} ${VERSION_CODENAME:-?})."
ok "Debian Trixie"

# --- 2. Passwordless sudo for the current (non-root) user ------------
step "Passwordless sudo for $(id -un)"
[ "$(id -u)" -ne 0 ] || die "run this as your dev user, not root."
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    ok "already configured"
else
    user_name="$(id -un)"
    sudoers_path="/etc/sudoers.d/00-mpd-${user_name}"
    echo "    No passwordless sudo. Asking for the root password (one-time; from \`su\`)."
    echo
    if ! su - -c "
        set -e
        if ! command -v sudo >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq; apt-get install -y -qq sudo
        fi
        install -d -m 0755 /etc/sudoers.d
        usermod -aG sudo '${user_name}'
        install -m 0440 -o root -g root /dev/null '${sudoers_path}'
        printf '%s ALL=(ALL) NOPASSWD:ALL\n' '${user_name}' > '${sudoers_path}'
        visudo -cf '${sudoers_path}' >/dev/null || { rm -f '${sudoers_path}'; exit 1; }
    "; then
        die "Failed to configure sudo. Wrong root password, or sudo couldn't be installed."
    fi
    ok "passwordless sudo enabled for ${user_name}"
fi

# --- 3. Network stack → systemd-networkd + systemd-resolved ----------
# Identical to mpd-prepare-adopt.sh: keep the DHCP address, convert
# whatever manages the link, converge over one reboot.
step "IPv6 off + IPv4 forwarding"
printf 'net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.lo.disable_ipv6 = 1\n' \
    | sudo tee /etc/sysctl.d/99-mpd-disable-ipv6.conf >/dev/null
printf 'net.ipv4.ip_forward = 1\n' | sudo tee /etc/sysctl.d/99-mpd-forwarding.conf >/dev/null
sudo sysctl --system >/dev/null 2>&1 || true
ok "IPv6 disabled, IPv4 forwarding enabled"

step "systemd-resolved + libnss-resolve"
need=()
dpkg -s systemd-resolved >/dev/null 2>&1 || need+=(systemd-resolved)
dpkg -s libnss-resolve   >/dev/null 2>&1 || need+=(libnss-resolve)
if [ "${#need[@]}" -gt 0 ]; then
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}"
fi
sudo systemctl enable systemd-resolved >/dev/null 2>&1 || true
ok "systemd-resolved + libnss-resolve installed"

step "Link manager → systemd-networkd (DHCP)"
iface="$(ip -4 -o route show default | awk '{print $5; exit}')"
[ -n "${iface}" ] || die "no default IPv4 route — cannot find the primary interface."
printf '[Match]\nName=%s\n\n[Network]\nDHCP=yes\n' "${iface}" \
    | sudo tee /etc/systemd/network/05-mpd.network >/dev/null
sudo systemctl enable systemd-networkd >/dev/null 2>&1
ok "wrote 05-mpd.network (DHCP on ${iface}), enabled systemd-networkd"

reboot_needed=0
if systemctl is-active --quiet NetworkManager; then
    sudo systemctl disable NetworkManager >/dev/null 2>&1 || true
    reboot_needed=1
    ok "NetworkManager disabled (purged after reboot)"
elif systemctl is-active --quiet networking && ! systemctl is-active --quiet systemd-networkd; then
    sudo sed -i -E "s/^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+${iface}([[:space:]].*)?$/# mpd-disabled: &/" \
        /etc/network/interfaces
    sudo systemctl disable networking >/dev/null 2>&1 || true
    reboot_needed=1
    ok "ifupdown neutralized for ${iface}"
else
    ok "link already on systemd-networkd"
fi

if [ "${reboot_needed}" = 1 ]; then
    echo
    echo "================================================================"
    echo "  Network stack reconfigured. REBOOT, then re-run this script:"
    echo "      sudo reboot"
    echo "================================================================"
    exit 0
fi

step "Readiness"
sudo systemctl start systemd-resolved >/dev/null 2>&1 || true
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl is-active --quiet systemd-resolved || die "systemd-resolved not active — reboot and re-run."
systemctl is-active --quiet systemd-networkd || die "systemd-networkd not active — reboot and re-run."
dns_ok=0; for _ in $(seq 1 15); do getent hosts deb.debian.org >/dev/null 2>&1 && { dns_ok=1; break; }; sleep 1; done
[ "${dns_ok}" = 1 ] || die "DNS not resolving — reboot and re-run."
if dpkg -s network-manager >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y purge network-manager network-manager-gnome >/dev/null 2>&1 || true
fi
ok "systemd-resolved + systemd-networkd active, DNS resolves"

# --- 4. Install mpd from source --------------------------------------
# 20-git-clone clones the repo to /opt/mpd (and creates /var/lib/mpd);
# 40/50 install deps + build the binary. Same steps adoption drives over
# SSH — here they run locally.
step "Install mpd (clone + build)"
if [ ! -d /opt/mpd/.git ]; then
    bash <(wget -qO- "${BOOTSTRAP_URL}/20-git-clone.sh")
else
    ok "already cloned at /opt/mpd"
fi
bash /opt/mpd/bootstrap/40-install-software.sh
bash /opt/mpd/bootstrap/50-build.sh
export PATH="/opt/mpd/bin:${PATH}"
ok "mpd built at /opt/mpd/bin/mpd"

# --- 5. mpd --vm-setup: generates the in-VM self-signed CA -----------
# No CA was pushed, so mpd generates its own and installs it in the
# system trust store. (A later `mpd-virt adopt` would push a Mac CA
# and re-root; both paths end at the same working platform.)
step "mpd --vm-setup (self-signed CA, generated in this VM)"
mpd --vm-setup

# --- 6. Pre-warm a database (best-effort) ----------------------------
# (The runtime container itself is created by `mpd --vm-setup` above.)
step "Pre-warming postgres (best-effort)"
mpd --db-create=postgres:latest && ok "postgres ready" || warn "postgres pre-warm deferred to first use"

# --- 7. GNOME launcher (only if a desktop is present) ---------------
if [ -d /usr/share/xsessions ] || command -v gnome-shell >/dev/null 2>&1; then
    step "GNOME launcher"
    apps_dir="${HOME}/.local/share/applications"; mkdir -p "${apps_dir}"
    cat > "${apps_dir}/mpd.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=mpd
Comment=Moodle Plugin Development — project status
Exec=xdg-open https://${nnn}.mpd.test/
Icon=applications-internet
Categories=Development;
Terminal=false
EOF
    update-desktop-database "${apps_dir}" >/dev/null 2>&1 || true
    ok "launcher opens https://${nnn}.mpd.test/"
fi

# --- 8. Done: SOCKS access + first-project instructions -------------
vm_ip="$(ip -4 -o addr show "${iface}" | awk '{print $4}' | cut -d/ -f1 | head -1)"
cat <<EOF

================================================================
  Sandbox ready — ${host} at ${vm_ip}
================================================================

In THIS VM (if it has a desktop), open Firefox and browse to:

    https://${nnn}.mpd.test/

From your HOST browser (macOS / Windows / Linux), reach it over an
SSH SOCKS proxy — no host routing or /etc/hosts needed
(requires sshd in the VM: sudo apt-get install openssh-server):

  1. Open the tunnel (leave it running):
         ssh -D 1080 -N ${USER:-skodak}@${vm_ip}

  2. Firefox → Settings → Network Settings → Manual proxy:
         SOCKS Host: 127.0.0.1   Port: 1080   (SOCKS v5)
         [x] Proxy DNS when using SOCKS v5

  3. Trust this sandbox's CA in Firefox (Settings → Privacy &
     Security → Certificates → View Certificates → Authorities →
     Import), from:
         /var/lib/mpd/conf/caroot/rootCA.pem
     (copy it out with: scp ${USER:-skodak}@${vm_ip}:/var/lib/mpd/conf/caroot/rootCA.pem .)

  4. Browse to:  https://${nnn}.mpd.test/

Create your first Moodle site (a few minutes) — mudev assembles the
tree from a recipe, then mpd configures and starts it:

    mkdir -p /srv/projects/moodle50 && cd \$_
    mudev clone moodle/release/5.0.1   # run 'mudev' alone to list recipes
    mpd init                           # register the new project
    mpd start                          # configure + start
    mdl-install                        # install Moodle
    # then browse to  https://moodle50.${nnn}.mpd.test/

Later, adopt this VM as a managed VM from a Mac (re-roots the CA to
the Mac's, projects survive):

    mpd-virt adopt ${nnn} ${vm_ip}
================================================================
EOF
