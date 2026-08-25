#!/bin/bash
# 70-configure-runtime.sh — configure what 60 installed: php.ini + FPM per
# version, `php` as the project-aware dispatcher, Composer, Node (nvm),
# the caddy frontdoor unit, /srv permissions. Runs as the dev user at
# runtime create, on every `mpd --vm-setup`, and after 60 in
# `mpd --vm-upgrade`. Idempotent; no apt.
#
#   70-configure-runtime.sh <container>
set -euo pipefail

CONTAINER_NAME="$1"

# shellcheck source=/dev/null
. /opt/mpd/assets/runtime/lib/php-configure.sh

echo "==> PHP ${MPD_PHP_VERSIONS}: php.ini, FPM pools"
for VER in $MPD_PHP_VERSIONS; do
    mpd_php_configure_version "$VER"
done

# /usr/bin/php -> the dispatcher in bin/, registered as the Debian
# alternative at priority 1000 and pinned, so IDE interpreter probes and
# `update-alternatives --config php` both see one consistent `php`.
echo "==> php alternative"
sudo rm -f /usr/local/bin/php   # legacy shim
PHP_ALT_SLAVES=()
if [ -f "/usr/share/man/man1/php${MPD_PHP_FALLBACK_VERSION}.1.gz" ]; then
    PHP_ALT_SLAVES=(--slave /usr/share/man/man1/php.1.gz php.1.gz \
        "/usr/share/man/man1/php${MPD_PHP_FALLBACK_VERSION}.1.gz")
fi
sudo update-alternatives --install /usr/bin/php php \
    /opt/mpd/assets/runtime/bin/php 1000 "${PHP_ALT_SLAVES[@]}"
sudo update-alternatives --set php /opt/mpd/assets/runtime/bin/php

echo "==> Composer, Node"
bash /opt/mpd/assets/runtime/bin/composer-install
bash /opt/mpd/assets/runtime/bin/node-install lts

# caddy runs AS the dev user: project keys under /srv/meta are 0600 to
# that user, which the packaged caddy.service (User=caddy) could not read.
# mpd-caddy.sh renders the Caddyfile from /srv/meta and reload-watches it.
echo "==> mpd-caddy.service"
sudo systemctl disable --now caddy.service 2>/dev/null || true
DEV_USER="$(id -un)"
sudo tee /etc/systemd/system/mpd-caddy.service >/dev/null << UNITEOF
[Unit]
Description=mpd in-runtime TLS frontdoor (caddy)
Documentation=file:///opt/mpd/docs/architecture.md
After=network.target

[Service]
User=${DEV_USER}
Group=${DEV_USER}
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
sudo systemctl restart mpd-caddy.service || true

# project-setup.sh creates subdirs here; setgid + world-writable.
chmod 02777 /srv/data

echo "Runtime '${CONTAINER_NAME}' configured: PHP ${MPD_PHP_VERSIONS}, php dispatcher, Composer, Node, caddy."
