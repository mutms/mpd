#!/bin/bash
# mpd-env.sh — shared helper sourced by Moodle project-type tools.
# Provides: PROJECT, PROJECT_DIR, moodle_run(), and all MPD_* env variables.
# Usage: source /opt/mpd/assets/vm/project_types/moodle/scripts/mpd-env.sh

if [[ "$PWD" =~ ^/srv/projects/([^/]+) ]]; then
    PROJECT="${BASH_REMATCH[1]}"
else
    echo "Error: must be run from within a project directory (/srv/projects/<project>/...)" >&2
    exit 1
fi

PROJECT_DIR="/srv/projects/${PROJECT}"

# moodle_run <relative-script-path> [args...]
# Runs a Moodle CLI script with php from the directory that holds it.
# Moodle 5.x split the tree — admin/cli/* stays at the root while
# admin/tool/* moved under public/ — so each path resolves on its own.
# The cwd matters: Moodle CLIs require config.php relative to __DIR__.
moodle_run() {
    local rel="$1"; shift
    if [ -f "${PROJECT_DIR}/${rel}" ]; then
        cd "${PROJECT_DIR}" || exit 1
    elif [ -f "${PROJECT_DIR}/public/${rel}" ]; then
        cd "${PROJECT_DIR}/public" || exit 1
    else
        echo "Error: ${rel} not found under ${PROJECT_DIR} or ${PROJECT_DIR}/public" >&2
        exit 1
    fi
    exec php "$rel" "$@"
}

# moodle_status — this project's status JSON from `mpd status --json`,
# fetched once per script (each call is about 0.2s). Ask mpd instead of
# reading /srv/meta; see AGENTS.md "Ask mpd, don't read its files".
moodle_status() {
    if [ -z "${_MPD_STATUS:-}" ]; then
        _MPD_STATUS=$(mpd status "$PROJECT" --json) || return 1
    fi
    printf '%s' "$_MPD_STATUS"
}

# moodle_status_field <jq-path> — one string out of moodle_status.
# Strings only: `// empty` treats a false boolean as absent.
moodle_status_field() {
    moodle_status | jq -r "$1 // empty"
}

# moodle_configured — succeeds when `mpd start` has run for this
# project, so the database exists and config.php has been written.
moodle_configured() {
    [ "$(moodle_status | jq -r '.configured')" = "true" ]
}

# moodle_db_table_count — prints how many tables this project's
# database holds; fails when there is no database. Tools use it to
# refuse acting on a project that still carries data.
moodle_db_table_count() {
    local engine host client
    engine=$(moodle_status_field '.database.engine') || return 1
    host=$(moodle_status_field '.database.host')
    [ -n "$engine" ] && [ -n "$host" ] || return 1

    case "$engine" in
        postgres)
            PGPASSWORD="${PROJECT}" psql -h "$host" -U "${PROJECT}" -d "${PROJECT}" -tAc \
                "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'"
            ;;
        mariadb|mysql)
            client="mariadb"
            [ "$engine" = "mysql" ] && client="mysql"
            # --skip-ssl: the client defaults SSL on, but the DB container
            # serves plaintext on the private network, so it would refuse.
            "$client" -h "$host" -u root -proot --skip-ssl -N -B -e \
                "SELECT count(*) FROM information_schema.tables WHERE table_schema='${PROJECT}'"
            ;;
        *)
            return 1
            ;;
    esac
}

# Layered MPD_* config via the whitelist parser, never raw `source`:
# a cloned project's mpd.env must not execute code.
PROJECT_NAME="${PROJECT}"
# shellcheck source=/dev/null
source /opt/mpd/assets/vm/lib/source-mpd-env.sh

# moodle_agent_log <tool> [args...] — append one JSON line about an
# mdl-agent-* call to /srv/data/<project>/agent/log.jsonl, so a later
# session can see what earlier ones did to the site (mdl-agent-log shows
# it). Records who called, when, from where and with what arguments, not
# the output. Best effort: a call is never refused because the log failed.
#
# The caller is named by MDL_AGENT_NAME / MDL_AGENT_SESSION when set, else
# worked out for Claude Code; empty means a person at a shell.
moodle_agent_log() {
    local tool="$1"; shift
    local datadir agent session
    datadir=$(moodle_status_field '.dataDir' 2>/dev/null) || return 0
    [ -n "$datadir" ] || return 0

    agent="${MDL_AGENT_NAME:-}"
    session="${MDL_AGENT_SESSION:-}"
    if [ -z "$agent" ] && [ -n "${CLAUDECODE:-}" ]; then
        agent="claude-code"
        session="${session:-${CLAUDE_CODE_SESSION_ID:-}}"
    fi

    (
        umask 077
        mkdir -p "${datadir}/agent"
        # Long code is cut: the log says what was done, it is not a copy.
        jq -cn --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg tool "$tool" \
            --arg agent "$agent" --arg session "$session" --arg cwd "$PWD" \
            '{time:$time, tool:$tool, agent:$agent, session:$session, cwd:$cwd,
              args:[$ARGS.positional[] | if length > 2000 then .[0:2000] + "…" else . end]}' \
            --args -- "$@" >>"${datadir}/agent/log.jsonl"
    ) 2>/dev/null || true
}
