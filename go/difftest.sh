#!/bin/bash
set -uo pipefail
# difftest.sh — compare Go (bin/gompd) output against Swift (bin/mpd).
#
# The Swift implementation has no tests, so during the port it serves as
# the specification: for every verb that both binaries implement, their
# output must match byte for byte. This is the check that proved the
# Mpd.Net refactor was a no-op, generalised.
#
# Add a line to COMMANDS as each verb is ported. Removing a line is only
# correct when the behaviour deliberately diverges — say so in a comment
# when you do.
#
# Run via `make go-difftest`. Requires both binaries built:
#     make install go-build
#
# Colour is off automatically: both binaries check isatty, and output is
# captured through a pipe here.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT="${REPO_DIR}/bin/mpd"
GO="${REPO_DIR}/bin/gompd"

# Verbs implemented by BOTH binaries. Read-only only — this script must
# never mutate state, since it runs them twice.
COMMANDS=(
    "list projects"
    "list runtimes"
    "list services"
    "list dbs"
    "show gotest1"
    "show nosuchproject"
)

# Verbs whose Swift and Go spellings differ during the port. Swift takes
# `--runtime <name>`; the Go CLI is cobra-shaped (`runtime <name>`), and
# the final rename will settle which one survives. Compared as a pair so
# the divergence is deliberate and visible rather than untested.
declare -a PAIRED=(
    "--runtime util|runtime util"
    "--runtime nosuchruntime|runtime nosuchruntime"
    "--check-hooks|check-hooks"
    # --start is read-mostly: it starts what already runs and refreshes
    # caches. Safe to run twice, so it belongs here rather than in
    # mutatetest.
    "--start|up"
)

for bin in "$SWIFT" "$GO"; do
    [ -x "$bin" ] || { echo "missing binary: $bin (run: make install go-build)" >&2; exit 1; }
done

pass=0
fail=0

for cmd in "${COMMANDS[@]}"; do
    # shellcheck disable=SC2086  # deliberate word splitting of the verb line
    if diff_out=$(diff <("$SWIFT" $cmd 2>&1) <("$GO" $cmd 2>&1)); then
        printf '  ok   mpd %s\n' "$cmd"
        pass=$((pass + 1))
    else
        printf '  FAIL mpd %s\n' "$cmd"
        printf '%s\n' "$diff_out" | sed 's/^/       /'
        fail=$((fail + 1))
    fi
done

for pair in "${PAIRED[@]}"; do
    swift_args="${pair%%|*}"
    go_args="${pair##*|}"
    # shellcheck disable=SC2086
    if diff_out=$(diff <("$SWIFT" $swift_args 2>&1) <("$GO" $go_args 2>&1)); then
        printf '  ok   mpd %s  ==  gompd %s\n' "$swift_args" "$go_args"
        pass=$((pass + 1))
    else
        printf '  FAIL mpd %s  vs  gompd %s\n' "$swift_args" "$go_args"
        printf '%s\n' "$diff_out" | sed 's/^/       /'
        fail=$((fail + 1))
    fi
done

printf '\n%d matching, %d differing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
