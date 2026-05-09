#!/bin/bash
# provision.sh — sandbox mpd-machine setup, run after take-over-vm.sh.
#
# Assumes:
#   - hostname is mpd-machine-sandbox
#   - passwordless sudo is configured for the current user
#   - the mpd repo is cloned at ~/Developer/mpd/
#
# All three are set up by the entry script (../take-over-vm.sh). Direct
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
    die "Passwordless sudo not configured. Run take-over-vm.sh first."
fi
ok "Passwordless sudo"

if [ ! -d "${REPO_DIR}/.git" ]; then
    die "Repo not cloned at ${REPO_DIR}. Run take-over-vm.sh first."
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
# MPD_CLIENT_OS=debian is a placeholder — the laptop-client recipe is
# skipped on .sandbox in Swift, and the field disappears entirely in the
# Phase 4 cleanup of MachineClientRecipe.
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
MPD_CLIENT_OS=debian
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

# --- Done ---------------------------------------------------------------
cat <<EOF

================================================================
  Sandbox ready — $(hostname)
================================================================

Open Firefox in this VM and browse to:

    https://mpd.test/

Create a Moodle project:

    mpd create moodle52 --git-repo=https://github.com/moodle/moodle.git --git-branch=MOODLE_502_STABLE
    mpd configure moodle52 MPD_DB=postgres:18
    mpd start moodle52

Then browse to:  https://moodle52.mpd.test/

================================================================
EOF
