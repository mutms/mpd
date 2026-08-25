# source-mpd-env.sh — loads the layered mpd.env files, exporting every MPD_*
# key for subprocesses. After this runs, every `MPD_*` value documented in
# any of the layered files is in the environment.
#
# This composes mpd's *config* keys only. The developer's general
# environment (~/.mpd-virt/runtime.env → /var/lib/mpd/env/runtime.env) is NOT
# a layer here — it is sourced into every runtime shell by the skel ~/.bashrc,
# ambient before any of this runs. A value it sets survives unless a layer
# below reassigns it.
#
# Layering (last assignment wins):
#   1. /opt/mpd/assets/vm/mpd-defaults.env — the developer's own runtime-wide
#      defaults, if any. Optional and normally absent: it arrives only if the
#      developer overlays one from ~/.mpd-virt/assets/vm/mpd-defaults.env.
#   2. /opt/mpd/assets/runtime/project_types/<type>/mpd-defaults.env —
#      project-type defaults (override layer 1).
#   3. /srv/projects/<project>/mpd.env — per-project, seeded from the project
#      type's template/mpd.env at create time. Wins over everything above.
#
# Per-project values win over type defaults, which win over the developer's
# defaults. Explicit `KEY=""` in any layer blocks fall-through from earlier
# layers (last-assignment-wins, even empty).
#
# The type is read from /srv/meta/<project>/project.json (written by
# mpd on every project configure/start). If that file is missing or the
# field is absent, layer 2 is silently skipped — layers 1+3 always load.
#
# SECURITY: env files are NOT bash-sourced — mpd.env can arrive from a cloned
# project repo, so every layer goes through a whitelist parser (below) that
# accepts only `MPD_[A-Z0-9_]+=…` lines, strips one layer of quoting, and
# assigns via `printf -v` + `export` (no `eval`, no `source`). A hostile
# `MPD_DB=$(rm -rf ~)` ends up the literal string, never executed. Format
# follows systemd EnvironmentFile (exec(5)).
#
# Caller must have $PROJECT_NAME set. Idempotent — safe to source multiple
# times in a script chain.
#
# Usage:
#   PROJECT_NAME=foo
#   source /opt/mpd/assets/runtime/lib/source-mpd-env.sh
#   PHP_VER="${MPD_PHP_VERSION:-$MPD_PHP_FALLBACK_VERSION}"

_mpd_load_env_file() {
    local file="$1"
    [ -f "$file" ] || return 0
    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip blank lines and `#` comments. Whitespace-only lines too.
        case "$line" in
            ''|\#*) continue ;;
        esac
        # Strict KEY=VALUE match — drop anything that doesn't fit the
        # MPD_<UPPER>=<…> shape. No leading whitespace, no other prefixes.
        [[ "$line" =~ ^(MPD_[A-Z0-9_]+)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        # Strip one layer of outer quoting (matches systemd EnvironmentFile).
        if [[ "$val" =~ ^\"(.*)\"$ ]]; then
            val="${BASH_REMATCH[1]}"
        elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
            val="${BASH_REMATCH[1]}"
        fi
        # printf -v assigns a string into a named variable without eval.
        printf -v "$key" '%s' "$val"
        export "$key"
    done < "$file"
}

# Layer 1+2: the developer's own defaults (optional, normally absent) + type
# defaults. The type comes from project.json (written by mpd on
# configure/start) and layer 2 is silently skipped when it is absent.
_mpd_load_env_file "/opt/mpd/assets/vm/mpd-defaults.env"
_mpd_meta="/srv/meta/${PROJECT_NAME}/project.json"
if [ -f "$_mpd_meta" ] && command -v jq >/dev/null 2>&1; then
    _mpd_type=$(jq -r '.type // empty' "$_mpd_meta" 2>/dev/null)
    if [ -n "$_mpd_type" ]; then
        _mpd_load_env_file "/opt/mpd/assets/runtime/project_types/${_mpd_type}/mpd-defaults.env"
    fi
    unset _mpd_type
fi
unset _mpd_meta

# Layer 3: per-project — untrusted (may come from a cloned repo), so parsed.
_mpd_load_env_file "/srv/projects/${PROJECT_NAME}/mpd.env"

unset -f _mpd_load_env_file

# VM identity — NOT a layer. Exported last and unconditionally, so no env
# file can override it: MPD_ZONE is a fact about which VM this is, not a
# preference. A project that could set its own zone would get a cert and a
# DNS record it isn't entitled to.
#
# Written by mpd (cli.VMMeta) on every --vm-setup / --vm-start.
# The conf dir it derives from is deliberately not mounted into
# containers, so the data volume is the only path in.
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
