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
