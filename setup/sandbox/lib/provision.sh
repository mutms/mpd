#!/bin/bash
# provision.sh — sandbox-side finalization, called by take-over-sandbox-vm.sh.
#
# Take-over has already run bootstrap/10-passwordless-sudo.sh and
# bootstrap/20-git-clone.sh, so the repo is cloned and `sudo -n` works.
# This script:
#   1. Runs the remaining bootstrap steps (30-50): networking, apt,
#      build.
#   2. Installs sandbox-specific tooling (VS Code).
#   3. Runs `mpd --vm-setup` to bring up podman networks, services, CA.
#   4. Pre-warms a PHP runtime + postgres for fast first `demo moodle`.
#   5. Drops GNOME desktop launchers.

set -euo pipefail

REPO_DIR=/opt/mpd

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
warn() { printf '    warn: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# --- Light preflight ---------------------------------------------------
[ -d "${REPO_DIR}/.git" ] || die "Repo not cloned at ${REPO_DIR}. Run take-over-sandbox-vm.sh first."
sudo -n true 2>/dev/null  || die "Passwordless sudo not configured. Run take-over-sandbox-vm.sh first."

# --- Remaining bootstrap steps (30-50) --------------------------------
# Sandbox VM = octet 000 (DHCP, no static IP pin).

bash "${REPO_DIR}/bootstrap/30-networking.sh" 0
bash "${REPO_DIR}/bootstrap/40-install-software.sh"
bash "${REPO_DIR}/bootstrap/50-build.sh"

# 50-build.sh prepends ~/.local/bin + /opt/mpd/bin to ~/.bashrc and also exports it
# inside its own shell — but since we invoked it via `bash …` (a
# subshell), the export doesn't reach us. Mirror it here so the
# `mpd --vm-setup` / `mpd --runtime-create` / `mpd --db-create` calls
# below find the just-built binary without spawning a new login shell.
export PATH="${REPO_DIR}/bin:${PATH}"

# --- VS Code (Microsoft official apt repo) -----------------------------
# Sandbox-specific: gives the in-VM GNOME desktop an IDE so the story
# is complete (terminal + browser + IDE, all inside the VM, no host hop).
# -o DPkg::Lock::Timeout: apt-get (unlike `apt`) has no default lock wait,
# and a sandbox VM is a full GNOME desktop — packagekitd is running by
# definition here. -o Acquire::Retries: survive a stalled download.
# Inlined: this script doesn't source bootstrap/00-common.sh.
# shellcheck disable=SC2034  # used unquoted below, intentionally word-split
APT_OPTS="-o DPkg::Lock::Timeout=300 -o Acquire::Retries=3"

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
        sudo env DEBIAN_FRONTEND=noninteractive apt-get $APT_OPTS update -qq
    fi
    sudo env DEBIAN_FRONTEND=noninteractive apt-get $APT_OPTS install -y code
    ok "Installed: VS Code"
fi

# --- mpd --vm-setup -------------------------------------------------------
step "Running 'mpd --vm-setup'"
mpd --vm-setup

# --- Pre-warm (best-effort) -------------------------------------------
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
# .desktop file so the user can find mpd in GNOME Activities and (if
# Desktop icons are enabled) on the desktop itself. Terminal=true keeps
# the launcher portable across GNOME (ptyxis), KDE (konsole), XFCE.
step "GNOME desktop launcher"
apps_dir="${HOME}/.local/share/applications"
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

if [ -d "${HOME}/Desktop" ]; then
    desktop_shortcut="${HOME}/Desktop/mpd.desktop"
    cp -f "$apps_shortcut" "$desktop_shortcut"
    chmod 0755 "$desktop_shortcut"
    # GNOME 'Desktop Icons NG' refuses to launch unless marked trusted.
    # No-op on KDE/XFCE; harmless if `gio` is missing.
    gio set "$desktop_shortcut" metadata::trusted true 2>/dev/null || true
    ok "Launcher: ${desktop_shortcut}"

    if [ -f /usr/share/applications/code.desktop ]; then
        code_shortcut="${HOME}/Desktop/code.desktop"
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

    https://000.mpd.test/

You'll also find an "mpd" launcher and a "Visual Studio Code"
launcher in GNOME Activities (and on your Desktop, if desktop icons
are on). Click "mpd" any time to drop into the interactive TUI.

For VS Code: install the "Remote - SSH" extension on first launch,
then connect to user@php.runtime.000.mpd.test and open
/srv/projects/<your-project>/. The runtime container lives in this
same VM, so the connection is local — no host↔VM hop.

Create a Moodle project:

    demo moodle v5.2.0

Or by hand:

    mpd create moodle52 --git-repo=https://github.com/moodle/moodle.git --git-branch=MOODLE_502_STABLE
    mpd configure moodle52 MPD_DB=postgres:18
    mpd start moodle52

Then browse to:  https://moodle52.000.mpd.test/

================================================================
EOF
