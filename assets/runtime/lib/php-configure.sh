#!/bin/bash
# php-configure.sh — shared PHP-version install/config helpers.
#
# Sourced (never executed) by two callers, so the package list and the
# per-version FPM/php.ini setup have exactly one definition:
#   - assets/runtime/build.sh   — bakes the current PHP set into the image
#   - assets/runtime/tools/php-install — adds a legacy version on demand
#
# Both run as the dev user with passwordless sudo (AGENTS.md §"Mandatory
# privilege rule"): the functions sudo the individual privileged ops.
#
# No `set -e` here — a sourced library must not change the caller's shell
# options.

# Extensions every Moodle-capable PHP needs. Kept together so build.sh and
# php-install install the same set.
MPD_PHP_REQUIRED_EXTS="cli fpm curl gd intl mbstring pgsql soap xml zip mysql"

# Extensions we install when the Sury index has them. Some lag for the
# newest PHP on Sury, so a missing one is skipped, not fatal.
MPD_PHP_OPTIONAL_EXTS="opcache redis apcu xmlrpc"

# mpd_php_package_list <ver> — echo the php<ver>-* packages to install for
# one version, dropping optionals that are not in the apt index. Needs the
# Sury repo already present in the index (apt-get update run).
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

# mpd_php_configure_version <ver> — file-only setup for one already-installed
# version: Moodle php.ini defaults (FPM + CLI), the default pool's unix
# socket, and enabling + starting php<ver>-fpm. Idempotent. No apt here.
mpd_php_configure_version() {
    local ver="$1" sapi ini_dir pool_conf

    for sapi in fpm cli; do
        ini_dir="/etc/php/${ver}/${sapi}/conf.d"
        if [ -d "$ini_dir" ]; then
            sudo tee "${ini_dir}/99-moodle.ini" >/dev/null << 'INIEOF'
max_input_vars = 10000
upload_max_filesize = 200M
post_max_size = 206M
zend.exception_ignore_args = On
INIEOF
        fi
    done

    # Default pool listens on a unix socket; per-project pools that
    # project-setup.sh writes listen on their own TCP ports.
    pool_conf="/etc/php/${ver}/fpm/pool.d/www.conf"
    if [ -f "$pool_conf" ]; then
        sudo sed -i "s|^listen = .*|listen = /run/php/php${ver}-fpm.sock|" "$pool_conf"
    fi

    if [ -f "/lib/systemd/system/php${ver}-fpm.service" ] || [ -f "/usr/lib/systemd/system/php${ver}-fpm.service" ]; then
        sudo systemctl enable "php${ver}-fpm"
        sudo systemctl start "php${ver}-fpm" || true
    else
        echo "Warning: php${ver}-fpm.service does not exist after install — continuing." >&2
    fi
}
