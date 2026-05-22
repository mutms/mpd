# bootstrap/00-common.sh
#
# Sourced by every other bootstrap step. Provides:
#   - logging helpers (step / ok / warn / die)
#   - hostname gate (Debian Trixie + canonical mpd-<NNN>/mpd-sandbox/mpd-template)
#   - one shared place for constants like the canonical hostname
#
# Not directly executable; sourced via `. "$(dirname "$0")/00-common.sh"`.
#
# Privilege rule (AGENTS.md): scripts run as the dev user; sudo is used per
# privileged command. Bootstrap step 10 (passwordless_sudo) is the one
# place that hasn't got sudo yet and uses `su -c` instead.

# --- Output helpers ----------------------------------------------------
# Shared shape across every bootstrap step and the in-VM mpd binary.
step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
warn() { printf '    warn: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# --- Hostname rules ---------------------------------------------------
# Canonical: mpd-NNN (NNN = 3 digits; 000 = sandbox; 100..254 = managed VM).
# Transitional (accepted at gate, rewritten by step 20):
#   mpd-sandbox  — the user-friendly name we tell sandbox installers to use;
#                  step 20 renames it to mpd-000.
#   mpd-template — the Parallels (or other hypervisor) template VM, before
#                  it's been cloned into a real numbered VM.

# Echo the current short hostname (everything before the first dot, if any).
current_hostname() {
    hostname -s 2>/dev/null || cat /etc/hostname | tr -d '[:space:]' | cut -d. -f1
}

# Validate the current hostname matches one of the accepted shapes.
# Used by run-all.sh before any step runs.
require_accepted_hostname() {
    local h
    h=$(current_hostname)
    case "$h" in
        mpd-template|mpd-sandbox) return 0 ;;
        mpd-[0-9][0-9][0-9])      return 0 ;;
    esac
    die "hostname '$h' is not accepted by bootstrap.
Set the hostname to one of:
  mpd-sandbox   (sandbox VM, Debian installer typed-name)
  mpd-template  (template VM, before cloning)
  mpd-NNN       (3-digit canonical form; NNN ∈ 000..254)"
}

# --- Distro gate -------------------------------------------------------
# Hard requirement: Debian Trixie. Other distros / releases vary in package
# names, Swift toolchain availability, NetworkManager defaults, etc.
require_debian_trixie() {
    [ -r /etc/os-release ] || die "/etc/os-release missing — cannot verify OS."
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "debian" ] \
        || die "bootstrap targets Debian (got ID=${ID:-unknown})."
    [ "${VERSION_CODENAME:-}" = "trixie" ] \
        || die "bootstrap targets Debian Trixie (got VERSION_CODENAME=${VERSION_CODENAME:-unknown})."
}
