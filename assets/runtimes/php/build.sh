#!/bin/bash
# build.sh — builds the php runtime on top of the runtime base.
#
# Phase-2 of runtime creation. Runs as the dev user (passwordless sudo
# available, used for individual privileged ops only). See AGENTS.md
# §"Mandatory privilege rule".
#
# Phase 1 (assets/runtime-base/bootstrap.sh) has already created the
# dev user, set up sshd, /etc/mpd identity, /srv/{projects,data,dbs,
# tools,personal} layout, and ~/.bashrc defaults.
#
# Installs: all PHP versions (8.1–8.5) with FPM, Composer, Node.js (nvm),
# DB client tools. No Apache — TLS termination and project routing run
# in the Caddy frontdoor sidecar attached to the pod.
set -euo pipefail

CONTAINER_NAME="$1"

export DEBIAN_FRONTEND=noninteractive

# All PHP versions to install
PHP_VERSIONS="8.1 8.2 8.3 8.4 8.5"

# ── Sury PHP repository ──────────────────────────────────────────────────────
sudo apt-get install -y --no-install-recommends apt-transport-https ca-certificates curl gnupg2 lsb-release

curl -fsSL https://packages.sury.org/php/apt.gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/sury-php.gpg

echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
    | sudo tee /etc/apt/sources.list.d/sury-php.list >/dev/null

sudo apt-get update -qq

# ── Install all PHP versions + DB clients in one apt pass ────────────────────
# Building the list once and installing in a single apt-get call avoids ~25
# separate dpkg invocations (5 versions × ~5 extension calls + DB clients).
# apt resolves dependencies once and downloads in parallel — significantly
# faster on a fresh runtime build.
REQUIRED_EXTS="cli fpm curl gd intl mbstring pgsql soap xml zip mysql"
# Optional extensions may lag for newest PHP versions on Sury, so we filter
# the list to packages that actually exist in the apt index instead of
# letting one missing optional take down the install.
OPTIONAL_EXTS="opcache redis apcu xmlrpc"

PKG_LIST=""
for VER in $PHP_VERSIONS; do
    for EXT in $REQUIRED_EXTS; do
        PKG_LIST="${PKG_LIST} php${VER}-${EXT}"
    done
    for EXT in $OPTIONAL_EXTS; do
        # PHP 8.5 bundles OPcache — no separate php8.5-opcache package.
        if [ "$VER" = "8.5" ] && [ "$EXT" = "opcache" ]; then
            continue
        fi
        if apt-cache show "php${VER}-${EXT}" >/dev/null 2>&1; then
            PKG_LIST="${PKG_LIST} php${VER}-${EXT}"
        else
            echo "Warning: optional extension php${VER}-${EXT} not available — skipping."
        fi
    done
done

echo "Installing PHP versions ${PHP_VERSIONS} + DB clients in one apt pass..."
# shellcheck disable=SC2086
sudo apt-get install -y --no-install-recommends \
    $PKG_LIST \
    postgresql-client \
    mariadb-client \
    default-mysql-client

# ── Per-version FPM configuration (file ops only — no apt) ────────────────────
for VER in $PHP_VERSIONS; do
    # Moodle-required php.ini settings (FPM and CLI)
    for SAPI in fpm cli; do
        INI_DIR="/etc/php/${VER}/${SAPI}/conf.d"
        if [ -d "$INI_DIR" ]; then
            sudo tee "${INI_DIR}/99-moodle.ini" >/dev/null << 'INIEOF'
max_input_vars = 10000
upload_max_filesize = 200M
post_max_size = 206M
zend.exception_ignore_args = On
INIEOF
        fi
    done

    # Configure FPM pool — listen on unix socket
    POOL_CONF="/etc/php/${VER}/fpm/pool.d/www.conf"
    if [ -f "$POOL_CONF" ]; then
        sudo sed -i "s|^listen = .*|listen = /run/php/php${VER}-fpm.sock|" "$POOL_CONF"
    fi

    # Enable and start FPM for this version if the unit exists.
    if [ -f "/lib/systemd/system/php${VER}-fpm.service" ] || [ -f "/usr/lib/systemd/system/php${VER}-fpm.service" ]; then
        sudo systemctl enable "php${VER}-fpm"
        sudo systemctl start "php${VER}-fpm" || true
    else
        echo "Warning: php${VER}-fpm.service does not exist after install — continuing."
    fi
done

# ── Runtime tools: /usr/local/bin/php symlink (project-aware version dispatcher) ──
# The php wrapper itself lives at /mnt/assets/runtimes/php/tools/php so edits
# on the host are live in the runtime; we install a symlink under
# /usr/local/bin/ for consumers that don't go through PATH (systemd, cron).
sudo ln -sf /mnt/assets/runtimes/php/tools/php /usr/local/bin/php

# ── Composer ─────────────────────────────────────────────────────────────────
bash /mnt/assets/runtimes/php/tools/composer-install

# ── Node.js (nvm, for Moodle JS tooling) ────────────────────────────────────
bash /mnt/assets/runtime-base/tools/node-install lts

# ── Data directory ──────────────────────────────────────────────────────────
# /srv/data already exists, dev-user-owned (bootstrap.sh). World-writable
# group bit needed for project-setup.sh subdir creation.
chmod 02777 /srv/data

# ── Tool symlinks + PATH wiring (see ARCHITECTURE.md §7) ────────────────────
# PATH order at SSH/login time: project-type tools first, runtime tools
# second, system PATH last. Profile.d files are sourced alphabetically and
# each prepends to PATH, so the file that's sourced LAST ends up FIRST in
# PATH. Naming guarantees the order:
#   mpd-tools-runtime.sh         (sourced first; ends up second in PATH)
#   mpd-tools-type-<type>.sh     (sourced last;  ends up first in PATH)

# Runtime-level tools.
RUNTIME_TOOLS_SRC="/mnt/assets/runtimes/php/tools"
RUNTIME_TOOLS_DST="/srv/tools/php"
if [ -d "$RUNTIME_TOOLS_SRC" ]; then
    mkdir -p "$RUNTIME_TOOLS_DST"
    for SCRIPT in "$RUNTIME_TOOLS_SRC"/*; do
        [ -f "$SCRIPT" ] || continue
        SCRIPT_NAME="$(basename "$SCRIPT")"
        ln -sf "$SCRIPT" "$RUNTIME_TOOLS_DST/$SCRIPT_NAME"
    done
    echo "export PATH=\"${RUNTIME_TOOLS_DST}:\$PATH\"" \
        | sudo tee /etc/profile.d/mpd-tools-runtime.sh >/dev/null
    sudo chmod 644 /etc/profile.d/mpd-tools-runtime.sh
    echo "Installed runtime tools → ${RUNTIME_TOOLS_DST}"
fi

# Project-type tools. Scan assets for project types with a tools/ directory.
ASSETS_RT="/mnt/assets/runtimes/php/project_types"
for TYPE_DIR in "${ASSETS_RT}"/*/tools; do
    [ -d "$TYPE_DIR" ] || continue
    TYPE_NAME="$(basename "$(dirname "$TYPE_DIR")")"
    TOOLS_DIR="/srv/tools/${TYPE_NAME}"
    mkdir -p "$TOOLS_DIR"
    # Symlink each executable tool. tools/ should contain only executables;
    # sourced helpers (like scripts/mpd-env.sh) live elsewhere by convention.
    for SCRIPT in "$TYPE_DIR"/*; do
        [ -f "$SCRIPT" ] || continue
        SCRIPT_NAME="$(basename "$SCRIPT")"
        ln -sf "$SCRIPT" "$TOOLS_DIR/$SCRIPT_NAME"
    done
    echo "export PATH=\"${TOOLS_DIR}:\$PATH\"" \
        | sudo tee "/etc/profile.d/mpd-tools-type-${TYPE_NAME}.sh" >/dev/null
    sudo chmod 644 "/etc/profile.d/mpd-tools-type-${TYPE_NAME}.sh"
    echo "Installed tools for '${TYPE_NAME}' → ${TOOLS_DIR}"
done

echo "PHP runtime '${CONTAINER_NAME}' build complete."
echo "PHP versions: ${PHP_VERSIONS} | FPM pools | php wrapper | Composer | Node (nvm)"
