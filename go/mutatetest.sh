#!/bin/bash
set -uo pipefail
# mutatetest.sh — verify a MUTATING verb produces the same result in Go
# as in Swift.
#
# difftest.sh cannot do this: it runs each command through both binaries,
# which for a mutating verb means running it twice. Here each verb runs
# once per implementation, from the same starting state, and the
# resulting state is compared:
#
#     reset → swift verb → snapshot A
#     reset → go    verb → snapshot B
#     compare A and B
#
# A snapshot is the state files plus what podman reports, normalised.
# JSON is compared **semantically** (via jq -S), not byte for byte:
# Swift writes `"key" : value` and Go writes `"key": value`, both valid
# and both parsed by every consumer, so a byte comparison would report a
# difference that does not exist for any reader.
#
# DESTRUCTIVE by design — it starts and stops containers. Run it on a
# disposable VM, which is what mpd VMs are.
#
# Usage: make go-mutatetest

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT="${REPO_DIR}/bin/mpd"
GO="${REPO_DIR}/bin/gompd"
STATE_DIR=/var/lib/mpd/state
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DB="${MPD_TEST_DB:-postgres:latest}"

for bin in "$SWIFT" "$GO"; do
    [ -x "$bin" ] || { echo "missing binary: $bin (run: make install go-build)" >&2; exit 1; }
done
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

# Capture everything ANY mpd verb is expected to affect.
#
# Deliberately broad rather than per-verb: a snapshot that only covers
# what the verb under test is *supposed* to touch cannot detect the two
# failures that matter most — a verb that changes something it shouldn't,
# and a verb that changes nothing at all. An earlier version captured
# only DB artifacts, so the first runtime case "passed" while comparing
# nothing relevant to runtimes.
snapshot() {
    local dest="$1"
    mkdir -p "$dest"

    # Persisted intent.
    jq -S . "${STATE_DIR}/databases.json" > "${dest}/databases.json" 2>/dev/null || echo '{}' > "${dest}/databases.json"
    jq -S . "${STATE_DIR}/projects.json"  > "${dest}/projects.json"  2>/dev/null || echo '{}' > "${dest}/projects.json"
    for meta in "${STATE_DIR}"/runtimes/*/meta.json; do
        [ -f "$meta" ] || continue
        jq -S . "$meta" > "${dest}/runtime-$(basename "$(dirname "$meta")").json"
    done

    # DNS fragments: one file per project/runtime, plus the managed ones.
    for conf in "${STATE_DIR}"/dnsmasq.d/*.conf; do
        [ -f "$conf" ] || continue
        sort "$conf" > "${dest}/dns-$(basename "$conf")"
    done

    # Ground truth: every mpd container and pod, not just databases.
    sudo podman ps -a --filter label=mpd.managed=true \
        --format '{{.Names}} {{.State}}' | sort > "${dest}/podman.txt"
    sudo podman pod ps --format '{{.Name}} {{.Status}}' | sort > "${dest}/pods.txt"
    # mpd-named volumes only. Images with a VOLUME directive (mariadb,
    # mysql) create an anonymous 64-hex volume per container, and those
    # accumulate across the two runs of a case — so an unfiltered list
    # always shows the second run with one extra and reports a
    # difference that is really "both leaked equally".
    #
    # NOTE those leaks are real: `podman rm` without -v strips neither.
    # Worth a `mpd --gc` sweep eventually; not this harness's problem.
    sudo podman volume ls --format '{{.Name}}' |
        grep -vE '^[0-9a-f]{64}$' | sort > "${dest}/volumes.txt"
}

pass=0
fail=0

# Each case: a name, the command that establishes the starting state,
# then the Swift and Go spellings of the verb under test.
run_case() {
    local name="$1" reset="$2" swift_cmd="$3" go_cmd="$4"

    eval "$reset" >/dev/null 2>&1
    eval "$SWIFT $swift_cmd" >"${WORK}/swift.out" 2>&1
    snapshot "${WORK}/swift"

    eval "$reset" >/dev/null 2>&1
    eval "$GO $go_cmd" >"${WORK}/go.out" 2>&1
    snapshot "${WORK}/go"

    if diff_out=$(diff -r "${WORK}/swift" "${WORK}/go"); then
        printf '  ok   %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s\n' "$name"
        printf '%s\n' "$diff_out" | sed 's/^/       /'
        fail=$((fail + 1))
    fi

    # Output is compared separately: a difference here is worth knowing
    # about but is not a state divergence, so report it distinctly.
    #
    # Normalised first, because some of podman's output is inherently
    # nondeterministic and would report a difference on two runs of the
    # SAME binary: layer blobs are copied in parallel so their order
    # varies, and container IDs are fresh every create. Left unfiltered,
    # every create case cries wolf and real differences get lost in it.
    normalise() {
        grep -vE '^(Copying (blob|config)|Writing manifest|Getting image source|Trying to pull|Storing signatures)' "$1" |
            grep -vE 'level=(warning|info) msg=' |
            sed -E 's/^[0-9a-f]{64}$/<container-id>/'
    }
    normalise "${WORK}/swift.out" > "${WORK}/swift.norm"
    normalise "${WORK}/go.out"    > "${WORK}/go.norm"
    #
    # KNOWN, UNDERSTOOD DIVERGENCE when captured through a pipe: Swift's
    # stdout is block-buffered when it is not a terminal, so its own
    # `print` lines flush AFTER the unbuffered output of child processes
    # (podman writes to the same fd directly). The `✓ …` line therefore
    # appears later than it should. Go writes unbuffered and prints in
    # true order. Run both under `script -qec … /dev/null` and the output
    # is byte-identical — verified — so this is a Swift buffering
    # artifact, not a behavioural difference. Do not "fix" Go to match
    # the piped ordering.
    if ! out_diff=$(diff "${WORK}/swift.norm" "${WORK}/go.norm"); then
        printf '       (output differs — see the buffering note in this script)\n'
        printf '%s\n' "$out_diff" | sed 's/^/       /'
    fi

    rm -rf "${WORK}/swift" "${WORK}/go"
}

run_case "db stop (from running)" \
    "$SWIFT --db-start $DB" \
    "--db-stop $DB" \
    "db stop $DB"

run_case "db stop (already stopped)" \
    "$SWIFT --db-stop $DB" \
    "--db-stop $DB" \
    "db stop $DB"

run_case "db start (from stopped)" \
    "$SWIFT --db-stop $DB" \
    "--db-start $DB" \
    "db start $DB"

run_case "db start (already running)" \
    "$SWIFT --db-start $DB" \
    "--db-start $DB" \
    "db start $DB"

# create/delete use a SECOND engine so the primary fixture survives the
# run: these cases end with the container removed, and leaving the main
# DB deleted would silently weaken every later difftest.
DB2="${MPD_TEST_DB2:-mariadb:latest}"

run_case "db create (from absent)" \
    "$SWIFT --db-delete $DB2 --yes" \
    "--db-create $DB2" \
    "db create $DB2"

run_case "db create (already exists, running)" \
    "$SWIFT --db-create $DB2" \
    "--db-create $DB2" \
    "db create $DB2"

run_case "db delete (existing)" \
    "$SWIFT --db-create $DB2" \
    "--db-delete $DB2 --yes" \
    "db delete $DB2 --yes"

# --- Project verbs ---------------------------------------------------
# gotest1 is a `bare` project on the util runtime — no database, no web
# server, so start/stop exercise the lifecycle without a heavy type.
PROJ="${MPD_TEST_PROJECT:-gotest1}"

run_case "project start (from stopped)" \
    "$SWIFT stop $PROJ" \
    "start $PROJ" \
    "start $PROJ"

run_case "project start (already running)" \
    "$SWIFT start $PROJ" \
    "start $PROJ" \
    "start $PROJ"

run_case "project stop (from running)" \
    "$SWIFT start $PROJ" \
    "stop $PROJ" \
    "stop $PROJ"

run_case "project stop (already stopped)" \
    "$SWIFT stop $PROJ" \
    "stop $PROJ" \
    "stop $PROJ"

# --- Runtime verbs ---------------------------------------------------
# `util` is the cheapest runtime to rebuild if something goes wrong, and
# gotest1 lives on it, so the "runtime has projects" path is exercised.
RT="${MPD_TEST_RUNTIME:-util}"

run_case "runtime stop (from running)" \
    "$SWIFT --runtime-start $RT" \
    "--runtime-stop $RT" \
    "runtime stop $RT"

run_case "runtime start (from stopped, restores projects)" \
    "$SWIFT --runtime-stop $RT" \
    "--runtime-start $RT" \
    "runtime start $RT"

# Leave the runtime running for later runs.
"$SWIFT" --runtime-start "$RT" >/dev/null 2>&1

# Leave the VM as we found it: primary fixture present and running,
# secondary engine gone.
"$SWIFT" --db-delete "$DB2" --yes >/dev/null 2>&1
"$SWIFT" --db-start "$DB" >/dev/null 2>&1

printf '\n%d matching, %d differing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
