#!/bin/bash
# build.sh — builds the php runtime on top of the runtime base.
#
# Phase-2 of runtime creation. Runs as the dev user (passwordless sudo
# available, used for individual privileged ops only). See AGENTS.md
# §"Mandatory privilege rule".
#
# Phase 1 (assets/runtime-base/bootstrap.sh) has already created the
# dev user, set up sshd, /etc/mpd identity, /srv/{projects,data,dbs,tools}
# layout, and ~/.bashrc defaults.
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
# golang-go + make build `mudev`, the Go binary that manages project
# checkouts inside the php runtime (see the mudev-install tool). `make`
# alone, not build-essential: Go needs a C compiler only for cgo, and
# mudev doesn't use it — build-essential would add ~200 MB to every php
# runtime for nothing. If mudev ever needs cgo, add gcc here.
# shellcheck disable=SC2086
sudo apt-get install -y --no-install-recommends \
    $PKG_LIST \
    postgresql-client \
    mariadb-client \
    default-mysql-client \
    golang-go \
    make

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
# The php wrapper itself lives at /opt/mpd/assets/runtimes/php/tools/php so edits
# on the host are live in the runtime; we install a symlink under
# /usr/local/bin/ for consumers that don't go through PATH (systemd, cron).
sudo ln -sf /opt/mpd/assets/runtimes/php/tools/php /usr/local/bin/php

# ── Composer ─────────────────────────────────────────────────────────────────
bash /opt/mpd/assets/runtimes/php/tools/composer-install

# ── Node.js (nvm, for Moodle JS tooling) ────────────────────────────────────
bash /opt/mpd/assets/runtime-base/tools/node-install lts

# ── Data directory ──────────────────────────────────────────────────────────
# /srv/data already exists, dev-user-owned (bootstrap.sh). World-writable
# group bit needed for project-setup.sh subdir creation.
chmod 02777 /srv/data

# ── Tool symlinks + PATH wiring (see ARCHITECTURE.md §7) ────────────────────
# Runtime + project-type tools land under /srv/tools/<rt>/ and
# /srv/tools/<type>/. PATH is set by the dev user's ~/.bashrc (shipped via
# skel) which globs every dir under /srv/tools/. No per-runtime/per-type
# /etc/profile.d/ drop-in is needed — and root deliberately has none of
# these on PATH (see AGENTS.md "Mandatory privilege rule").
#
# PATH order at shell start is base → runtime → types (each prepends, so
# types win). The shipped .bashrc ranks them explicitly, reading the
# runtime's own name from /etc/mpd/runtime — it does not rely on the
# alphabetical order of /srv/tools/*/, which ranks `php` above `moodle`
# and gets the precedence exactly backwards.

# Each /srv/tools/<n> entry is a symlink to the assets tools/ directory
# itself, not a directory of per-file symlinks. Adding or removing a tool
# under assets/ then takes effect immediately in every existing runtime —
# no rebuild, nothing to re-link. `/srv/tools/*/` still matches, because
# the glob resolves symlinks to directories.
link_tools_dir() {
    src="$1"; dst="$2"
    # Replace a real directory left by an older per-file provisioning run.
    if [ -d "$dst" ] && [ ! -L "$dst" ]; then
        rm -rf "$dst"
    fi
    ln -sfn "$src" "$dst"
}

# Runtime-level tools.
RUNTIME_TOOLS_SRC="/opt/mpd/assets/runtimes/php/tools"
RUNTIME_TOOLS_DST="/srv/tools/php"
if [ -d "$RUNTIME_TOOLS_SRC" ]; then
    link_tools_dir "$RUNTIME_TOOLS_SRC" "$RUNTIME_TOOLS_DST"
    echo "Installed runtime tools → ${RUNTIME_TOOLS_DST}"
fi

# Project-type tools. Scan assets for project types with a tools/ directory.
ASSETS_RT="/opt/mpd/assets/runtimes/php/project_types"
for TYPE_DIR in "${ASSETS_RT}"/*/tools; do
    [ -d "$TYPE_DIR" ] || continue
    TYPE_NAME="$(basename "$(dirname "$TYPE_DIR")")"
    TOOLS_DIR="/srv/tools/${TYPE_NAME}"
    link_tools_dir "$TYPE_DIR" "$TOOLS_DIR"
    echo "Installed tools for '${TYPE_NAME}' → ${TOOLS_DIR}"
done

echo "PHP runtime '${CONTAINER_NAME}' build complete."
echo "PHP versions: ${PHP_VERSIONS} | FPM pools | php wrapper | Composer | Node (nvm)"
