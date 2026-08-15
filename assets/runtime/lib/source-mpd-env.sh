# source-mpd-env.sh — loads the layered mpd.env files, exporting every MPD_*
# key for subprocesses. After this runs, every `MPD_*` value documented in
# any of the four layered files is in the environment.
#
# Layering (last assignment wins):
#   1. /opt/mpd/assets/runtime/mpd-defaults.env — runtime-wide defaults.
#      Single source of truth for "the default value of MPD_<RT>_*".
#   2. /opt/mpd/assets/runtime/project_types/<type>/mpd-defaults.env —
#      project-type defaults (override the runtime layer).
#   3. /var/lib/mpd/env/mpd-virt.env — the developer's own defaults, shared
#      by every VM they run: authored on the Mac at ~/.mpd-virt/mpd-virt.env
#      and pushed in by mpd-virt. Bind-mounted RO from the VM into runtime
#      containers at the same absolute path (see podman.EnvMountRO).
#   4. /srv/projects/<project>/mpd.env — per-project, seeded from the project
#      type's template/mpd.env at create time. Wins over everything above.
#
# Per-project values win over the developer's, which win over type defaults,
# which win over runtime defaults. Explicit `KEY=""` in any layer blocks
# fall-through from earlier layers (last-assignment-wins, even when empty).
#
# The type is read from /srv/meta/<project>/project.json (written by
# mpd on every project configure/start). If that file is missing or the
# field is absent, layer 2 is silently skipped — layers 3+4 always load.
#
# SECURITY: env files are NOT bash-sourced. They are read line by line by a
# whitelist parser that:
#   - accepts only lines matching `^MPD_[A-Z0-9_]+=…$`
#   - silently drops everything else (blank lines, `#` comments, stray text)
#   - strips at most one layer of `"…"` or `'…'` quoting
#   - assigns via `printf -v` and `export NAME` (no `eval`, no `source`)
# A malicious project mpd.env containing `MPD_DB=$(rm -rf ~)` ends up with
# `MPD_DB` set to the literal string `$(rm -rf ~)` — never executed. Format
# follows the systemd EnvironmentFile spec (systemd.exec(5)).
#
# Caller must have $PROJECT_NAME set. Idempotent — safe to source multiple
# times in a script chain.
#
# Usage:
#   PROJECT_NAME=foo
#   source /opt/mpd/assets/runtime/lib/source-mpd-env.sh
#   PHP_VER="${MPD_PHP_VERSION}"

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

# Layer 1+2: runtime + type defaults. There is one runtime, so layer 1 is
# unconditional; the type comes from project.json (written by mpd on
# configure/start) and layer 2 is silently skipped when it is absent.
_mpd_load_env_file "/opt/mpd/assets/runtime/mpd-defaults.env"
_mpd_meta="/srv/meta/${PROJECT_NAME}/project.json"
if [ -f "$_mpd_meta" ] && command -v jq >/dev/null 2>&1; then
    _mpd_type=$(jq -r '.type // empty' "$_mpd_meta" 2>/dev/null)
    if [ -n "$_mpd_type" ]; then
        _mpd_load_env_file "/opt/mpd/assets/runtime/project_types/${_mpd_type}/mpd-defaults.env"
    fi
    unset _mpd_type
fi
unset _mpd_meta

# Layer 3+4: developer-wide + per-project (always sourced).
_mpd_load_env_file "/var/lib/mpd/env/mpd-virt.env"
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
