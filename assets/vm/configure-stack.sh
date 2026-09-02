#!/bin/bash
# configure-stack.sh — install and configure the dev stack: the PHP
# matrix, php.ini + FPM pools, the php dispatcher, Composer, Node,
# /srv permissions. Run by `mpd --vm-setup` as the dev user. Idempotent.
#
# Composer and Node are upstream fetches rather than packages, which is
# the separate reason they are not part of apt provisioning.
set -euo pipefail

# shellcheck source=/dev/null
. /opt/mpd/assets/vm/lib/php-configure.sh

MPD_APT_LOCK_TIMEOUT="${MPD_APT_LOCK_TIMEOUT:-300}"
apt_get() {
    sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get -o DPkg::Lock::Timeout="${MPD_APT_LOCK_TIMEOUT}" \
                -o Dpkg::Options::=--force-confdef \
                -o Dpkg::Options::=--force-confold \
                "$@"
}

PHP_PKGS=()
for VER in $MPD_PHP_VERSIONS; do
    # shellcheck disable=SC2207
    PHP_PKGS+=($(mpd_php_package_list "$VER"))
done
missing=()
for pkg in "${PHP_PKGS[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "==> Installing PHP ${MPD_PHP_VERSIONS} (${#missing[@]} packages)"
    apt_get install -y -qq --no-install-recommends "${missing[@]}"
fi

echo "==> PHP ${MPD_PHP_VERSIONS}: php.ini, FPM pools"
for VER in $MPD_PHP_VERSIONS; do
    mpd_php_configure_version "$VER"
done

# Register bin/php as the Debian alternative and pin it, so IDE probes of
# /usr/bin/php see one consistent dispatcher.
echo "==> php alternative"
PHP_ALT_SLAVES=()
if [ -f "/usr/share/man/man1/php${MPD_PHP_FALLBACK_VERSION}.1.gz" ]; then
    PHP_ALT_SLAVES=(--slave /usr/share/man/man1/php.1.gz php.1.gz \
        "/usr/share/man/man1/php${MPD_PHP_FALLBACK_VERSION}.1.gz")
fi
sudo update-alternatives --install /usr/bin/php php \
    /opt/mpd/assets/vm/bin/php 1000 "${PHP_ALT_SLAVES[@]}"
sudo update-alternatives --set php /opt/mpd/assets/vm/bin/php

echo "==> Composer, Node"
bash /opt/mpd/assets/vm/bin/composer-install
bash /opt/mpd/assets/vm/bin/node-install lts

# project-setup.sh creates subdirs here; setgid + world-writable.
chmod 02777 /srv/data

echo "Dev stack configured: PHP ${MPD_PHP_VERSIONS}, php dispatcher, Composer, Node."
