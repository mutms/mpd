#!/bin/bash
# php-configure.sh — shared PHP-version install/config helpers, sourced by
# configure-stack.sh and bin/php-install so
# the version list, package list and per-version setup have one definition.
#
# No `set -e` here — a sourced library must not change the caller's shell
# options.

# The PHP versions the VM carries.
MPD_PHP_VERSIONS="8.1 8.2 8.3 8.4 8.5"

# Used when no mpd.env layer sets MPD_PHP_VERSION. Keep in sync with bin/php.
MPD_PHP_FALLBACK_VERSION="8.3"

# Extensions every Moodle-capable PHP needs.
MPD_PHP_REQUIRED_EXTS="cli fpm curl gd intl mbstring pgsql soap xml zip mysql"

# Installed only when the Sury index has them; a missing one is skipped,
# not fatal.
MPD_PHP_OPTIONAL_EXTS="opcache redis apcu xmlrpc"

# mpd_php_package_list <ver> — echo the php<ver>-* packages for one
# version, dropping optionals absent from the apt index. Needs the Sury
# repo in the index already.
mpd_php_package_list() {
    local ver="$1" ext list=""
    for ext in $MPD_PHP_REQUIRED_EXTS; do
        list="${list} php${ver}-${ext}"
    done
    for ext in $MPD_PHP_OPTIONAL_EXTS; do
        # PHP 8.5+ bundles OPcache — no separate php<ver>-opcache package.
        if [ "$ext" = "opcache" ] && { [ "$ver" = "8.5" ] || [ "$ver" = "8.6" ]; }; then
            continue
        fi
        if apt-cache show "php${ver}-${ext}" >/dev/null 2>&1; then
            list="${list} php${ver}-${ext}"
        else
            echo "Warning: optional extension php${ver}-${ext} not available — skipping." >&2
        fi
    done
    printf '%s' "${list# }"
}

# mpd_php_configure_version <ver> — configure one installed version:
# Moodle php.ini defaults, the default pool's unix socket, and
# enabling + starting php<ver>-fpm. Idempotent; no apt.
mpd_php_configure_version() {
    local ver="$1" sapi ini_dir ini_file pool_conf ini_changed=0 ini

    # session.upload_progress is off as the PHP project advises for
    # CVE-2026-115560; Moodle does not use it.
    ini='memory_limit = 256M
max_input_vars = 10000
upload_max_filesize = 200M
post_max_size = 206M
zend.exception_ignore_args = On
session.upload_progress.enabled = 0'

    for sapi in fpm cli; do
        ini_dir="/etc/php/${ver}/${sapi}/conf.d"
        ini_file="${ini_dir}/99-moodle.ini"
        if [ -d "$ini_dir" ] && [ "$(cat "$ini_file" 2>/dev/null)" != "$ini" ]; then
            printf '%s\n' "$ini" | sudo tee "$ini_file" >/dev/null
            if [ "$sapi" = fpm ]; then
                ini_changed=1
            fi
        fi
    done

    # The default pool listens on a unix socket; per-project pools listen
    # on their own TCP ports.
    pool_conf="/etc/php/${ver}/fpm/pool.d/www.conf"
    if [ -f "$pool_conf" ]; then
        sudo sed -i "s|^listen = .*|listen = /run/php/php${ver}-fpm.sock|" "$pool_conf"
    fi

    if [ -f "/lib/systemd/system/php${ver}-fpm.service" ] || [ -f "/usr/lib/systemd/system/php${ver}-fpm.service" ]; then
        sudo systemctl enable "php${ver}-fpm"
        # A running FPM reads php.ini only at start, so a changed file needs a restart.
        if [ "$ini_changed" = 1 ]; then
            sudo systemctl restart "php${ver}-fpm" || true
        else
            sudo systemctl start "php${ver}-fpm" || true
        fi
    else
        echo "Warning: php${ver}-fpm.service does not exist after install — continuing." >&2
    fi
}
