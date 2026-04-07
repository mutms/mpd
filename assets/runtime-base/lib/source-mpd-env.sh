# source-mpd-env.sh — loads the layered mpd.env files, exporting every MPD_*
# key for subprocesses. After this runs, every `MPD_*` value documented in
# any of the four layered files is in the environment.
#
# Layering (last assignment wins):
#   1. /mnt/assets/runtimes/<rt>/mpd-defaults.env — runtime-wide defaults.
#      Single source of truth for "the default value of MPD_<RT>_*".
#   2. /mnt/assets/runtimes/<rt>/project_types/<type>/mpd-defaults.env —
#      project-type defaults (override the runtime layer).
#   3. /home/<user>/mpd-user.env — symlink into the bind-mounted host file
#      (~/.mpd/mpd-user.env on the host). Per-developer cross-project overrides.
#   4. /srv/projects/<project>/mpd.env — per-project, seeded from the project
#      type's mpd-template.env at create time. Wins over everything above.
#
# Per-project values win over per-developer, which win over type defaults,
# which win over runtime defaults. Explicit `KEY=""` in any layer blocks
# fall-through from earlier layers (last-assignment-wins, even when empty).
#
# Runtime + type are read from /srv/meta/<project>/project.json (written by
# Swift on every project configure/start). If that file is missing or fields
# are absent, layers 1+2 are silently skipped — layers 3+4 always load.
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
# Caller must have $PROJECT_NAME set. The script runs as the (one and only)
# dev user, so $HOME is the per-developer mpd-user.env location — no lookup
# needed. Idempotent — safe to source multiple times in a script chain.
#
# Usage:
#   PROJECT_NAME=foo
#   source /mnt/assets/runtime-base/lib/source-mpd-env.sh
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

# Layer 1+2: runtime + type defaults. Read runtime/type from project.json
# (written by Swift on configure/start). Both fields are required for the
# defaults files to load; if either is empty, defaults are silently skipped.
_mpd_meta="/srv/meta/${PROJECT_NAME}/project.json"
if [ -f "$_mpd_meta" ] && command -v jq >/dev/null 2>&1; then
    _mpd_runtime=$(jq -r '.runtime // empty' "$_mpd_meta" 2>/dev/null)
    _mpd_type=$(jq -r '.type // empty' "$_mpd_meta" 2>/dev/null)
    if [ -n "$_mpd_runtime" ]; then
        _mpd_load_env_file "/mnt/assets/runtimes/${_mpd_runtime}/mpd-defaults.env"
        if [ -n "$_mpd_type" ]; then
            _mpd_load_env_file "/mnt/assets/runtimes/${_mpd_runtime}/project_types/${_mpd_type}/mpd-defaults.env"
        fi
    fi
    unset _mpd_runtime _mpd_type
fi
unset _mpd_meta

# Layer 3+4: per-developer + per-project (always sourced).
_mpd_load_env_file "${HOME}/mpd-user.env"
_mpd_load_env_file "/srv/projects/${PROJECT_NAME}/mpd.env"

unset -f _mpd_load_env_file
