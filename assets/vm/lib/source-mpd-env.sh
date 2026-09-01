# source-mpd-env.sh — load the layered mpd.env files, exporting every
# MPD_* key. Caller must set $PROJECT_NAME. Idempotent.
#
# Config keys only: the developer's vm.env is ambient shell
# environment, sourced by ~/.bashrc before this runs, not a layer.
#
# Layering (last assignment wins, even an empty value):
#   1. /opt/mpd/assets/vm/mpd-defaults.env — developer's VM-wide
#      defaults; optional and normally absent.
#   2. project_types/<type>/mpd-defaults.env — type defaults. The type
#      comes from /srv/meta/<project>/project.json; skipped when absent.
#   3. /srv/projects/<project>/mpd.env — per-project, wins over all.
#
# SECURITY: env files are never bash-sourced — mpd.env can arrive from a
# cloned repo. The parser accepts only `MPD_[A-Z0-9_]+=…` lines, strips
# one layer of quoting, and assigns via `printf -v` (no eval, no source),
# so a hostile value stays a literal string. Format follows systemd
# EnvironmentFile (exec(5)).
#
# Usage:
#   PROJECT_NAME=foo
#   source /opt/mpd/assets/vm/lib/source-mpd-env.sh
#   PHP_VER="${MPD_PHP_VERSION:-$MPD_PHP_FALLBACK_VERSION}"

_mpd_load_env_file() {
    local file="$1"
    [ -f "$file" ] || return 0
    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        # Drop any line that does not fit the MPD_<UPPER>=<…> shape.
        [[ "$line" =~ ^(MPD_[A-Z0-9_]+)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        # Strip one layer of outer quoting (matches systemd EnvironmentFile).
        if [[ "$val" =~ ^\"(.*)\"$ ]]; then
            val="${BASH_REMATCH[1]}"
        elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
            val="${BASH_REMATCH[1]}"
        fi
        printf -v "$key" '%s' "$val"
        export "$key"
    done < "$file"
}

# Layers 1+2: developer defaults, then type defaults.
_mpd_load_env_file "/opt/mpd/assets/vm/mpd-defaults.env"
_mpd_meta="/srv/meta/${PROJECT_NAME}/project.json"
if [ -f "$_mpd_meta" ] && command -v jq >/dev/null 2>&1; then
    _mpd_type=$(jq -r '.type // empty' "$_mpd_meta" 2>/dev/null)
    if [ -n "$_mpd_type" ]; then
        _mpd_load_env_file "/opt/mpd/assets/vm/project_types/${_mpd_type}/mpd-defaults.env"
    fi
    unset _mpd_type
fi
unset _mpd_meta

# Layer 3: per-project.
_mpd_load_env_file "/srv/projects/${PROJECT_NAME}/mpd.env"

unset -f _mpd_load_env_file

# VM identity — not a layer. Exported last so no env file can override it:
# a project that could set its own zone would get a cert and a DNS record
# it is not entitled to. vm.json is written by mpd on --vm-setup/--vm-start.
_mpd_vm_meta="/srv/meta/vm.json"
if [ -f "$_mpd_vm_meta" ] && command -v jq >/dev/null 2>&1; then
    MPD_ZONE=$(jq -r '.zone // empty' "$_mpd_vm_meta" 2>/dev/null)
    MPD_VM_ID=$(jq -r '.vmId // empty' "$_mpd_vm_meta" 2>/dev/null)
    export MPD_ZONE MPD_VM_ID
fi
unset _mpd_vm_meta

# Fail loudly rather than composing `https://project./` from an empty zone.
if [ -z "${MPD_ZONE:-}" ]; then
    echo "MPD_ZONE unavailable: /srv/meta/vm.json is missing, unreadable, or jq is not installed." >&2
    echo "Run 'mpd --start' on the VM to republish it." >&2
    return 1 2>/dev/null || exit 1
fi
