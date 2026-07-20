# bootstrap/00-common.sh
#
# Sourced by the local bootstrap steps (30-60). Provides logging helpers
# only — by the time these steps run, the hostname/OS gates in step 10
# have already validated the VM.
#
# Not directly executable; sourced via `. "$(dirname "$0")/00-common.sh"`.
#
# The two wgettable scripts (10-passwordless-sudo.sh, 20-git-clone.sh)
# DO NOT source this file — they inline their own helpers because they
# can be invoked before the mpd repo exists on the VM.

# --- Output helpers ----------------------------------------------------
step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
warn() { printf '    warn: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# --- apt ----------------------------------------------------------------
# Seconds to wait for the dpkg/apt locks instead of failing immediately.
#
# Debian ships `Binary::apt::DPkg::Lock::Timeout "120"` — note the
# `Binary::apt::` scope: it applies to the `apt` command only, NOT to
# `apt-get`, which still gives up the instant the lock is busy. On a
# desktop-flavoured template that is a near-certainty rather than a race:
# an auto-login GNOME session starts `packagekitd`, which grabs the lock
# to check for updates at exactly the moment bootstrap wants it. The
# failure looks like "Could not get lock /var/lib/dpkg/lock-frontend …
# held by process N (packagekitd)".
#
# So every apt-get call in bootstrap passes this explicitly. Waiting is
# the right behaviour: the competing job is short-lived, and bootstrap is
# not interactive, so there is nobody to retry by hand.
MPD_APT_LOCK_TIMEOUT="${MPD_APT_LOCK_TIMEOUT:-300}"

# Retries for failed/stalled downloads. Set explicitly rather than
# relying on the compiled-in default, which `apt-config dump` doesn't
# report — so on a given image you cannot tell whether you get 0 or 3.
#
# Bootstrap pulls `swiftlang` at ~400 MB, an order of magnitude larger
# than anything else it fetches, which makes it the one most likely to
# meet a CDN hiccup mid-transfer. Without retries a single stalled
# connection fails the whole step; with them apt reconnects and resumes.
MPD_APT_RETRIES="${MPD_APT_RETRIES:-3}"

# apt-get wrapper: non-interactive, waits for the lock, retries stalled
# fetches. Use everywhere instead of calling apt-get directly.
apt_get() {
    sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get -o DPkg::Lock::Timeout="${MPD_APT_LOCK_TIMEOUT}" \
                -o Acquire::Retries="${MPD_APT_RETRIES}" "$@"
}
