#!/bin/bash
# build.sh — builds the unified runtime on top of the runtime base.
#
# Phase-2 of runtime creation. Runs as the dev user (passwordless sudo
# available, used for individual privileged ops only). See AGENTS.md
# §"Mandatory privilege rule".
#
# Phase 1 (assets/runtime/bootstrap.sh) has already created the
# dev user, set up sshd, /etc/mpd identity, /srv/{projects,data,dbs,tools}
# layout, and ~/.bashrc defaults.
#
# Installs: all PHP versions (8.1–8.5) with FPM, Composer, Node.js (nvm),
# DB client tools, and caddy (apt) — the in-runtime TLS frontdoor that
# terminates HTTPS for every project URL (mpd-caddy.service, below).
set -euo pipefail

CONTAINER_NAME="$1"

export DEBIAN_FRONTEND=noninteractive

# All PHP versions to install
PHP_VERSIONS="8.1 8.2 8.3 8.4 8.5"

# Oldest supported PHP — what the `php` dispatcher falls back to outside a
# project tree. Keep in sync with MPD_PHP_FALLBACK_VERSION in tools/php.
PHP_FALLBACK_VERSION="8.2"

# ── Sury PHP repository ──────────────────────────────────────────────────────
sudo apt-get install -y --no-install-recommends apt-transport-https ca-certificates curl gnupg2 lsb-release

curl -fsSL https://packages.sury.org/php/apt.gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/sury-php.gpg

echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
    | sudo tee /etc/apt/sources.list.d/sury-php.list >/dev/null

sudo apt-get update -qq

# ── Install all PHP versions + DB clients + caddy in one apt pass ────────────
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

echo "Installing PHP versions ${PHP_VERSIONS} + DB clients + caddy in one apt pass..."
# No Go toolchain here on purpose. mudev is the only thing that ever
# needed one, and it is now built once on the VM and bind-mounted into
# every runtime read-only, so a per-runtime golang-go would be a
# second copy of a compiler nothing compiles with.
# shellcheck disable=SC2086
sudo apt-get install -y --no-install-recommends \
    $PKG_LIST \
    postgresql-client \
    mariadb-client \
    default-mysql-client \
    caddy \
    inotify-tools \
    jq

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

# ── `php` as a real Debian alternative ───────────────────────────────────────
# The project-aware dispatcher lives at /opt/mpd/assets/runtime/tools/php
# (bind-mounted, so host edits are live). Register it in the alternatives
# system rather than shimming it in under /usr/local/bin: the Sury packages
# register /usr/bin/phpX.Y at priorities 81…85, we register at 1000 and pin
# it, so /usr/bin/php -> /etc/alternatives/php -> the dispatcher. Anything
# that expects the Debian-standard interpreter path — PhpStorm's CLI
# interpreter probe above all — sees one consistent `php`, and
# `update-alternatives --config php` still lets a real version be selected.
sudo rm -f /usr/local/bin/php   # legacy shim; shadowed /usr/bin/php on PATH

PHP_ALT_SLAVES=()
if [ -f "/usr/share/man/man1/php${PHP_FALLBACK_VERSION}.1.gz" ]; then
    # Without a slave declaration, selecting our alternative would drop the
    # `man php` link that the versioned packages provide.
    PHP_ALT_SLAVES=(--slave /usr/share/man/man1/php.1.gz php.1.gz \
        "/usr/share/man/man1/php${PHP_FALLBACK_VERSION}.1.gz")
fi

sudo update-alternatives --install /usr/bin/php php \
    /opt/mpd/assets/runtime/tools/php 1000 "${PHP_ALT_SLAVES[@]}"
sudo update-alternatives --set php /opt/mpd/assets/runtime/tools/php

# ── Composer ─────────────────────────────────────────────────────────────────
bash /opt/mpd/assets/runtime/tools/composer-install

# ── Node.js (nvm, for Moodle JS tooling and node project types) ─────────────
bash /opt/mpd/assets/runtime/tools/node-install lts

# ── Caddy: the in-runtime TLS frontdoor ──────────────────────────────────────
# Project certs and keys are generated on the VM and land under
# /srv/meta/<project>/ with the key readable only by the dev user (0600),
# so caddy must run AS the dev user — the packaged caddy.service (User=caddy)
# could never read them. mpd-caddy.service replaces it: same apt binary,
# driven by a script that renders the Caddyfile from /srv/meta/*/urls.json
# and reload-watches /srv/meta (assets/runtime/caddy/mpd-caddy.sh,
# bind-mounted so host edits are live). AmbientCapabilities grants the
# :80/:443 bind to the non-root unit.
sudo systemctl disable --now caddy.service 2>/dev/null || true

DEV_USER="$(id -un)"
sudo tee /etc/systemd/system/mpd-caddy.service >/dev/null << UNITEOF
[Unit]
Description=mpd in-runtime TLS frontdoor (caddy)
Documentation=file:///opt/mpd/docs/ARCHITECTURE.md
After=network.target

[Service]
User=${DEV_USER}
Group=${DEV_USER}
# Dev-user-writable spot for the generated Caddyfile; recreated each boot.
RuntimeDirectory=mpd-caddy
Environment=CADDYFILE=/run/mpd-caddy/Caddyfile
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=/bin/bash /opt/mpd/assets/runtime/caddy/mpd-caddy.sh
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
UNITEOF

sudo systemctl daemon-reload
sudo systemctl enable mpd-caddy.service
sudo systemctl start mpd-caddy.service || true

# ── Data directory ──────────────────────────────────────────────────────────
# /srv/data already exists, dev-user-owned (bootstrap.sh). World-writable
# group bit needed for project-setup.sh subdir creation.
chmod 02777 /srv/data

echo "Runtime '${CONTAINER_NAME}' build complete."
echo "PHP versions: ${PHP_VERSIONS} | FPM pools | php wrapper | Composer | Node (nvm) | caddy frontdoor"
