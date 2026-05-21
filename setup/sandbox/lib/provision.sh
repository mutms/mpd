#!/bin/bash
# provision.sh — sandbox mpd-machine setup, run after take-over-sandbox-vm.sh.
#
# Assumes:
#   - hostname is mpd-machine-sandbox
#   - passwordless sudo is configured for the current user
#   - the mpd repo is cloned at ~/Developer/mpd/
#
# All three are set up by the entry script (../take-over-sandbox-vm.sh). Direct
# re-invocation is supported (idempotent) for iterating after a failure.

set -euo pipefail

REPO_DIR="$HOME/Developer/mpd"

# --- Output helpers (matching ubuntu-kvm/lib/common.sh style) ---
step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
warn() { printf '    warn: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# --- Light preflight ----------------------------------------------------

step "Preflight"

if [ ! -r /etc/os-release ]; then
    die "/etc/os-release missing — cannot verify OS."
fi
# shellcheck disable=SC1091
. /etc/os-release
if [ "${ID:-}" != "debian" ] || [ "${VERSION_CODENAME:-}" != "trixie" ]; then
    die "This script targets Debian Trixie (13). Detected: ${ID:-unknown}/${VERSION_CODENAME:-unknown}."
fi
ok "Debian Trixie"

if ! sudo -n true 2>/dev/null; then
    die "Passwordless sudo not configured. Run take-over-sandbox-vm.sh first."
fi
ok "Passwordless sudo"

if [ ! -d "${REPO_DIR}/.git" ]; then
    die "Repo not cloned at ${REPO_DIR}. Run take-over-sandbox-vm.sh first."
fi
ok "Repo at ${REPO_DIR}"

# --- Apt-install build dependencies ------------------------------------
# Done BEFORE the network-stack switch below, so apt's name resolution is
# still served by NetworkManager directly (the simple, known-good path).
# podman is installed by `mpd --setup`.
step "Build dependencies"
required_pkgs=(
    build-essential pkg-config make swiftlang
    libnss3-tools qemu-guest-agent
)
missing_pkgs=()
for pkg in "${required_pkgs[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing_pkgs+=("$pkg")
done
if [ ${#missing_pkgs[@]} -gt 0 ]; then
    sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "${missing_pkgs[@]}"
    ok "Installed: ${missing_pkgs[*]}"
else
    ok "All required packages already installed"
fi

# --- Standardize the network stack: systemd-resolved fed by NetworkManager
# Debian Trixie with GNOME desktop ships with NetworkManager writing
# /etc/resolv.conf directly; systemd-resolved is not installed. mpd-machine
# expects systemd-resolved active (mpd/Environment/Machine/MachineIntegration
# .requireSystemdResolvedActive). The other mpd-machine platforms get there
# via cloud-init; sandbox does it here.
#
# Order is important to avoid a broken-DNS window:
#   1. Write NM drop-in declaring `dns=systemd-resolved` (no effect yet).
#   2. apt-install systemd-resolved — postinst enables+starts the service
#      and turns /etc/resolv.conf into a stub symlink to 127.0.0.53.
#   3. Restart NetworkManager so it reads the drop-in and pushes upstream
#      DNS (from DHCP / the active connection) into systemd-resolved via
#      D-Bus instead of writing /etc/resolv.conf.
# libnss-resolve makes glibc NSS go through resolved (so getent/curl use
# the stub even without /etc/resolv.conf). It's a Recommends of
# systemd-resolved but we're using --no-install-recommends, so request it.
step "Network stack — systemd-resolved fed by NetworkManager"
nm_conf_dir=/etc/NetworkManager/conf.d
nm_drop_in=${nm_conf_dir}/10-mpd-dns.conf
nm_drop_in_body=$'[main]\ndns=systemd-resolved\n'
if [ ! -f "$nm_drop_in" ] || [ "$(sudo cat "$nm_drop_in" 2>/dev/null || true)" != "$nm_drop_in_body" ]; then
    sudo install -d -m 755 "$nm_conf_dir"
    printf '%s' "$nm_drop_in_body" | sudo install -m 644 /dev/stdin "$nm_drop_in"
    ok "Wrote ${nm_drop_in}"
else
    ok "${nm_drop_in} already in place"
fi

if ! dpkg -s systemd-resolved >/dev/null 2>&1 || ! dpkg -s libnss-resolve >/dev/null 2>&1; then
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        systemd-resolved libnss-resolve
    ok "Installed: systemd-resolved + libnss-resolve"
else
    ok "systemd-resolved + libnss-resolve already installed"
fi

# Postinst usually enables+starts systemd-resolved on its own; make it
# explicit so re-runs converge even if the unit was disabled by hand.
sudo systemctl enable --now systemd-resolved >/dev/null 2>&1 || true
if ! systemctl is-active --quiet systemd-resolved; then
    die "systemd-resolved did not come up after install — investigate with: systemctl status systemd-resolved"
fi
ok "systemd-resolved active"

# Restart NM so the dns=systemd-resolved drop-in takes effect. On the
# Trixie GNOME default, NM keeps the active connection up across restart
# (continue-active behavior), so any in-VM terminal or SSH session stays
# connected.
sudo systemctl restart NetworkManager

# Restart resolved AFTER NM is up. NM's "continue-active" restart does
# NOT reliably re-push DNS into resolved when the dns plugin has just
# flipped from `default` to `systemd-resolved` — resolved sits with no
# upstream nameserver and every lookup fails ("Temporary failure in
# name resolution"). `nmcli device reapply` does not fix it either
# (tested). What does: restarting resolved forces a fresh D-Bus name
# acquisition on `org.freedesktop.resolve1`; NM's resolved-watcher
# fires on that event and pushes DNS over D-Bus. Brief 1s pause so
# NM finishes settling before resolved bounces.
sleep 1
sudo systemctl restart systemd-resolved

ok_dns=0
for _ in $(seq 1 30); do
    if getent hosts deb.debian.org >/dev/null 2>&1; then
        ok_dns=1
        break
    fi
    sleep 1
done
if [ "$ok_dns" -eq 1 ]; then
    ok "DNS resolves through systemd-resolved (deb.debian.org)"
else
    cat >&2 <<'EOF'

============================================================
DNS via systemd-resolved did not come up within 30 seconds
after restarting NetworkManager + systemd-resolved.

Manual recovery (idempotent):

    sudo systemctl restart systemd-resolved
    getent hosts deb.debian.org   # should succeed

Then re-run take-over-sandbox-vm.sh — it's idempotent and picks
up where it left off (build deps and systemd-resolved are
already installed; the remaining steps are mpd build,
mpd --setup, pre-warm, and the GNOME launchers).

Inspect: resolvectl status;
         nmcli -t -f IP4.DNS device show;
         journalctl -u NetworkManager -u systemd-resolved -b \
             --no-pager | tail -50
============================================================
EOF
    die "Aborting — see message above."
fi

# --- VS Code (Microsoft official apt repo) -----------------------------
# Gives the sandbox an in-VM IDE so the GNOME desktop story is complete:
# terminal + browser + IDE, all running inside the VM, no SSH hop to the
# host. Idempotent — re-runs are no-ops.
step "VS Code"
if command -v code >/dev/null 2>&1; then
    ok "VS Code already installed ($(code --version | head -n1))"
else
    if [ ! -f /usr/share/keyrings/microsoft.gpg ]; then
        curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
            | gpg --dearmor \
            | sudo tee /usr/share/keyrings/microsoft.gpg >/dev/null
    fi
    if [ ! -f /etc/apt/sources.list.d/vscode.list ]; then
        echo "deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
            | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
        sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    fi
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y code
    ok "Installed: VS Code"
fi

# --- Build mpd ----------------------------------------------------------
step "Building mpd"
if ! command -v swift >/dev/null 2>&1; then
    die "swift not on PATH after apt install. Check: dpkg -l swiftlang"
fi
ok "$(swift --version | head -n1)"

cd "$REPO_DIR"
make install
[ -x "${REPO_DIR}/bin/mpd" ] || die "Expected ${REPO_DIR}/bin/mpd after 'make install'."
ok "Built ${REPO_DIR}/bin/mpd"

# --- Symlink onto PATH --------------------------------------------------
step "Installing /usr/local/bin/mpd"
sudo ln -sf "${REPO_DIR}/bin/mpd" /usr/local/bin/mpd
ok "/usr/local/bin/mpd → ${REPO_DIR}/bin/mpd"

# --- Write platform.env -------------------------------------------------
step "Platform identity"
conf_dir="${REPO_DIR}/conf"
platform_env="${conf_dir}/platform.env"
mkdir -p "$conf_dir"
if [ -f "$platform_env" ] && grep -q '^MPD_PLATFORM=sandbox$' "$platform_env"; then
    ok "${platform_env} already configured for sandbox"
else
    cat > "$platform_env" <<EOF
# mpd platform identity — written by sandbox/lib/provision.sh.
# Lives under conf/ so it survives 'mpd --uninstall'.
MPD_PLATFORM=sandbox
MPD_VM_IP=
MPD_INSTANCE_SUFFIX=
EOF
    chmod 0644 "$platform_env"
    ok "Wrote ${platform_env}"
fi

# --- mpd --setup --------------------------------------------------------
step "Running 'mpd --setup'"
mpd --setup

# --- Pre-warm (best-effort, mirrors ubuntu-kvm symmetry) ---------------
step "Pre-warming demo runtime + database (best-effort)"
if mpd --runtime-create=php; then
    ok "PHP runtime built"
else
    warn "PHP runtime pre-warm failed; will provision lazily on first use"
fi
if mpd --db-create=postgres:latest; then
    ok "postgres:latest ready"
else
    warn "postgres:latest pre-warm failed; will provision lazily on first use"
fi

# --- GNOME desktop launcher --------------------------------------------
# Drops a .desktop file so the user can find mpd in GNOME Activities and
# (if Desktop icons are enabled) on the desktop itself. Launches the
# interactive TUI in the user's default terminal — Terminal=true keeps
# this portable across GNOME (ptyxis), KDE (konsole), XFCE (xfce4-terminal).
step "GNOME desktop launcher"
apps_dir="$HOME/.local/share/applications"
apps_shortcut="${apps_dir}/mpd.desktop"
mkdir -p "$apps_dir"
cat > "$apps_shortcut" <<EOF
[Desktop Entry]
Type=Application
Name=mpd
Comment=Moodle Plugin Development — interactive TUI
Exec=mpd --tui
Icon=utilities-terminal
Categories=Development;
Terminal=true
StartupNotify=false
EOF
chmod 0755 "$apps_shortcut"
update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
ok "Launcher: ${apps_shortcut}"

if [ -d "$HOME/Desktop" ]; then
    desktop_shortcut="$HOME/Desktop/mpd.desktop"
    cp -f "$apps_shortcut" "$desktop_shortcut"
    chmod 0755 "$desktop_shortcut"
    # GNOME 'Desktop Icons NG' refuses to launch unless the file is marked
    # trusted. No-op on KDE/XFCE; harmless if `gio` is missing.
    gio set "$desktop_shortcut" metadata::trusted true 2>/dev/null || true
    ok "Launcher: ${desktop_shortcut}"

    # Mirror VS Code's system-wide launcher to the desktop so the IDE
    # icon sits next to the mpd one.
    if [ -f /usr/share/applications/code.desktop ]; then
        code_shortcut="$HOME/Desktop/code.desktop"
        cp -f /usr/share/applications/code.desktop "$code_shortcut"
        chmod 0755 "$code_shortcut"
        gio set "$code_shortcut" metadata::trusted true 2>/dev/null || true
        ok "Launcher: ${code_shortcut}"
    fi
fi

# --- Done ---------------------------------------------------------------
cat <<EOF

================================================================
  Sandbox ready — $(hostname)
================================================================

Open Firefox in this VM and browse to:

    https://mpd.test/

You'll also find an "mpd" launcher and a "Visual Studio Code"
launcher in GNOME Activities (and on your Desktop, if desktop icons
are on). Click "mpd" any time to drop into the interactive TUI.

For VS Code: install the "Remote - SSH" extension on first launch,
then connect to user@php.runtime.mpd.test (or whichever runtime
holds your project) and open /srv/projects/<your-project>/. The
runtime container lives in this same VM, so the connection is
local — no host↔VM hop.

To use mpd's tools (demo, etc.) in THIS shell right now, pick up the
PATH drop-in that 'mpd --setup' just installed:

    source /etc/profile.d/mpd-machine.sh

Any new SSH session will pick it up automatically.

Create a Moodle project:

    demo moodle v5.2.0

Or by hand:

    mpd create moodle52 --git-repo=https://github.com/moodle/moodle.git --git-branch=MOODLE_502_STABLE
    mpd configure moodle52 MPD_DB=postgres:18
    mpd start moodle52

Then browse to:  https://moodle52.mpd.test/

================================================================
EOF
