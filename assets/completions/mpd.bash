# mpd bash completion shim. Forwards to `mpd --complete` for the
# candidate set — see go/internal/cli/complete.go; new flags and verbs
# need only Go edits.

_mpd() {
    local IFS=$'\n'
    local cur cword candidates
    cword=$COMP_CWORD
    cur="${COMP_WORDS[$cword]}"

    candidates=$(command mpd --complete "$cword" "${COMP_WORDS[@]}" 2>/dev/null)

    # mpd already prefix-filters; hand the full set to compgen so
    # word-break edge cases (cur containing '=') do not double-filter.
    COMPREPLY=( $(compgen -W "$candidates" -- "$cur") )
}

complete -F _mpd mpd
