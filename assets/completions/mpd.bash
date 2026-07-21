# mpd bash completion shim.
#
# Forwards to `mpd --complete` for the actual candidate set — see
# go/internal/cli/complete.go. Adding new flags/verbs only needs Go edits;
# this shim doesn't have to change.

_mpd() {
    local IFS=$'\n'
    local cur cword candidates
    cword=$COMP_CWORD
    cur="${COMP_WORDS[$cword]}"

    candidates=$(command mpd --complete "$cword" "${COMP_WORDS[@]}" 2>/dev/null)

    # `compgen -W` filters by prefix; mpd already prefix-filters, but we hand
    # the full set to compgen so word-break edge cases (e.g. cur containing '=')
    # don't double-filter.
    COMPREPLY=( $(compgen -W "$candidates" -- "$cur") )
}

complete -F _mpd mpd
