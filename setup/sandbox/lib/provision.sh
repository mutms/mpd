#!/bin/bash
# provision.sh — sandbox-side finalization, called by take-over-sandbox-vm.sh.
#
# By this point the take-over script has:
#   - validated the hostname (mpd-sandbox or mpd-000) and the Debian Trixie OS
#   - enabled passwordless sudo for the dev user
#   - apt-installed git
#   - cloned mpd at ~/Developer/mpd
#
# This script:
#   1. Runs the shared bootstrap (apt packages, network stack, mpd build,
#      hostname → mpd-000, platform.env). Idempotent; safe to re-run.
#   2. Adds sandbox-specific tooling (VS Code).
#   3. Runs `mpd --setup` to bring up podman networks, services, CA, etc.
#   4. Pre-warms a PHP runtime + postgres so the first `demo moodle` is fast.
#   5. Drops a GNOME desktop launcher.
#
# Everything in step 1 is shared with mpd-virt's managed-VM create flow.
# Steps 2–5 are sandbox-only (GNOME, in-VM IDE).

set -euo pipefail

REPO_DIR="$HOME/Developer/mpd"

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
warn() { printf '    warn: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# --- Light preflight ---------------------------------------------------
[ -d "${REPO_DIR}/.git" ] || die "Repo not cloned at ${REPO_DIR}. Run take-over-sandbox-vm.sh first."
sudo -n true 2>/dev/null  || die "Passwordless sudo not configured. Run take-over-sandbox-vm.sh first."

# --- Shared bootstrap -------------------------------------------------
# Heavy lifting: sudoers no-op (already set), networking + hostname
# rename to mpd-000, apt package set, podman-restart, mpd build,
# ~/.bashrc PATH wiring, platform.env.
step "Running bootstrap (apt, networking, build)"
bash "${REPO_DIR}/bootstrap/run-all.sh" 0

# --- VS Code (Microsoft official apt repo) -----------------------------
# Sandbox-specific: gives the in-VM GNOME desktop an IDE so the story is
# complete (terminal + browser + IDE, all inside the VM, no host hop).
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

# --- mpd --setup -------------------------------------------------------
step "Running 'mpd --setup'"
mpd --setup

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

Create a Moodle project:

    demo moodle v5.2.0

Or by hand:

    mpd create moodle52 --git-repo=https://github.com/moodle/moodle.git --git-branch=MOODLE_502_STABLE
    mpd configure moodle52 MPD_DB=postgres:18
    mpd start moodle52

Then browse to:  https://moodle52.mpd.test/

================================================================
EOF
