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
if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "26.04" ]; then
    die "This script targets Ubuntu 26.04 LTS (detected: ${ID:-unknown}/${VERSION_ID:-unknown})."
fi
ok "Ubuntu 26.04 LTS"

if ! sudo -n true 2>/dev/null; then
    die "Passwordless sudo not configured. Run take-over-sandbox-vm.sh first."
fi
ok "Passwordless sudo"

if [ ! -d "${REPO_DIR}/.git" ]; then
    die "Repo not cloned at ${REPO_DIR}. Run take-over-sandbox-vm.sh first."
fi
ok "Repo at ${REPO_DIR}"

# --- Apt-install build dependencies ------------------------------------
# Single-shot install. git/curl/ca-certificates/systemd-resolved/spice-vdagent
# already ship with default Ubuntu desktop. podman is installed by `mpd --setup`.
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
