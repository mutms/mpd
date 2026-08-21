#!/bin/bash
set -euo pipefail
# migrate-vm-network.sh — move an existing mpd VM to the /etc/hosts DNS
# layout. Run once, by hand, on each VM set up before this change.
#
# What it removes (mpd --vm-setup never looks for these — it assumes a
# VM that never had them):
#   - /var/lib/mpd/state/dns/            the old per-record hosts files
#   - /etc/systemd/resolved.conf.d/mpd.conf
#                                        the systemd-resolved routing of
#                                        *.mpd.test to dnsmasq, plus the
#                                        search domain it carried
# Then it runs `mpd --vm-setup`, which writes the new dnsmasq config, the
# cloud-init drop-in where cloud-init exists, and the DNS block in
# /etc/hosts.
#
# Safe to re-run: every step is a no-op once done.

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }

if [ ! -x /opt/mpd/bin/mpd ]; then
    echo "mpd is not built: /opt/mpd/bin/mpd missing. Run: make -C /opt/mpd install" >&2
    exit 1
fi

step "Old DNS record files"
if [ -d /var/lib/mpd/state/dns ]; then
    rm -rf /var/lib/mpd/state/dns
    ok "removed /var/lib/mpd/state/dns/"
else
    ok "already gone"
fi

step "systemd-resolved routing drop-in"
if [ -f /etc/systemd/resolved.conf.d/mpd.conf ]; then
    sudo rm -f /etc/systemd/resolved.conf.d/mpd.conf
    # restart, not reload: a reload keeps the ~mpd.test routing domain in
    # resolved's global state; a restart drops it, and networkd hands the
    # link's DNS servers straight back.
    if systemctl is-active --quiet systemd-resolved; then
        sudo systemctl restart systemd-resolved
    fi
    ok "removed /etc/systemd/resolved.conf.d/mpd.conf"
else
    ok "already gone"
fi

step "mpd --vm-setup"
/opt/mpd/bin/mpd --vm-setup

step "Check"
echo "  /etc/hosts block:"
grep -A40 '^# BEGIN mpd' /etc/hosts | sed 's/^/    /'
echo
echo "  Resolution on the VM (via /etc/hosts):"
getent hosts runtime | sed 's/^/    /'
echo
echo "  Nothing should point systemd-resolved at mpd any more:"
if resolvectl status 2>/dev/null | grep -q '~mpd.test'; then
    echo "    WARNING: resolvectl still routes ~mpd.test — run: sudo systemctl restart systemd-resolved" >&2
else
    echo "    ok"
fi
