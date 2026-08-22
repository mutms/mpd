#!/bin/bash
# 60-install-software.sh — apt for the runtime: dist-upgrade, then every
# package a runtime needs (tools, all PHP versions, DB clients, caddy).
# The one package list; no configuration here (that is 70).
#
# Runs in three places, identical each time:
#   - the Containerfile, as root, to pre-bake the published image
#   - runtime create, as the dev user, right after 50 (a fast no-op on
#     a current image)
#   - `mpd --vm-upgrade`, as the dev user, to bring an existing runtime
#     forward in place — a runtime is upgraded, never rebuilt for this
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt_get() {
    sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 \
                -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/php-configure.sh"

# apt-get update exits 0 when every index fetch fails, so a container that
# cannot resolve gets an unrelated "package not available" screens later.
# Name the cause, and give a just-created container's network a moment.
resolved=false
for _ in 1 2 3 4 5; do
    if getent hosts deb.debian.org >/dev/null 2>&1; then
        resolved=true
        break
    fi
    sleep 2
done
if [ "$resolved" != true ]; then
    echo "cannot resolve deb.debian.org from inside the runtime; its resolver:" >&2
    sed -n 's/^nameserver/    nameserver/p' /etc/resolv.conf >&2
    echo "Check on the VM: systemctl status mpd-dnsmasq; getent hosts deb.debian.org" >&2
    exit 1
fi

echo "==> apt-get update + dist-upgrade"
apt_get update -qq
apt_get dist-upgrade -y -qq

# Repos: Sury for every PHP version; PGDG because Debian's postgresql-client
# is older than mpd's default server and pg_dump refuses a newer server.
echo "==> Third-party repositories (Sury PHP, PGDG)"
apt_get install -y -qq --no-install-recommends apt-transport-https ca-certificates curl gnupg2 lsb-release
curl -fsSL https://packages.sury.org/php/apt.gpg | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/sury-php.gpg
echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
    | sudo tee /etc/apt/sources.list.d/sury-php.list >/dev/null
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/pgdg.gpg
echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt/ $(lsb_release -sc)-pgdg main" \
    | sudo tee /etc/apt/sources.list.d/pgdg.list >/dev/null
apt_get update -qq

# Base: systemd as PID 1, sshd, sudo, developer tools (the last line is for
# AI agents; not `gh` — useless until it stores a token here).
BASE_PKGS=(
    systemd systemd-sysv sudo openssh-server openssh-client
    bash-completion bc bzip2 curl dnsutils file findutils git gzip htop
    iproute2 iputils-ping jq less lftp locales locales-all lsof man-db mc
    nano net-tools netcat-openbsd patch procps psmisc rsync screen socat
    strace tar telnet time tmux tree unzip vim wget whois xz-utils zip
    shellcheck shfmt ripgrep
)

# PHP: every version in MPD_PHP_VERSIONS with the Moodle extension set
# (lib/php-configure.sh). Not golang-go: mudev is built on the VM and
# bind-mounted in.
PHP_PKGS=()
for VER in $MPD_PHP_VERSIONS; do
    # shellcheck disable=SC2207
    PHP_PKGS+=($(mpd_php_package_list "$VER"))
done

# DB clients and the in-runtime TLS frontdoor (caddy; its watcher needs
# inotify-tools).
STACK_PKGS=(
    postgresql-client mariadb-client default-mysql-client
    caddy inotify-tools
)

echo "==> Installing packages (PHP ${MPD_PHP_VERSIONS}, DB clients, caddy, tools)"
apt_get install -y -qq --no-install-recommends "${BASE_PKGS[@]}" "${PHP_PKGS[@]}" "${STACK_PKGS[@]}"
