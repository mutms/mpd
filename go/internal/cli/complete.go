package cli

import (
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/state"
)

// Shell completion candidate emitter — the single source of truth for
// both bash and zsh.
//
// The shims under assets/completions/ invoke `mpd --complete <cword>
// <word0> <word1> …` and feed these lines back to compadd / COMPREPLY.
// Dynamic rather than a static script because mpd's grammar depends on
// filesystem state: which projects, runtimes and databases exist. Hand-
// writing that grammar twice, once per shell, would drift.
//
// Latency budget: every Tab press forks mpd. Keep this path to state-file
// reads and directory listings — no podman calls, no network.

// ProjectVerbs are the tokens accepted as the first positional argument.
// They are reserved as project names, so a project can never collide with
// a verb.
var ProjectVerbs = []string{"configure", "create", "delete", "help", "run", "show", "start", "stop"}

// IsProjectVerb reports whether a token is a project verb.
func IsProjectVerb(token string) bool {
	for _, v := range ProjectVerbs {
		if v == token {
			return true
		}
	}
	return false
}

// globalFlags is every long flag mpd accepts. Mirrors the flag set in
// cmd/mpd/main.go — add new entries in both places.
var globalFlags = []string{
	"--vm-setup",
	"--vm-start",
	"--vm-stop",
	"--vm-restart",
	"--runtime-create",
	"--runtime-start",
	"--runtime-stop",
	"--runtime-delete",
	"--runtime",
	"--db-create",
	"--db-start",
	"--db-stop",
	"--db-delete",
	"--vm-status",
	"--check-hooks",
	"--web",
	"--yes",
	"--debug",
	"--help",
}

// Complete prints one candidate per line. Errors map to "no candidates"
// rather than surfacing: the shell must never see a diagnostic where it
// expects a word list.
func Complete(out io.Writer, cword int, words []string, s state.Store, a assets.Tree) {
	prefix := ""
	if cword >= 0 && cword < len(words) {
		prefix = words[cword]
	}
	for _, c := range candidates(cword, words, s, a) {
		if strings.HasPrefix(c, prefix) {
			fmt.Fprintln(out, c)
		}
	}
}

func candidates(cword int, words []string, s state.Store, a assets.Tree) []string {
	// words[0] is "mpd" itself.
	if cword <= 1 {
		prefix := ""
		if cword < len(words) {
			prefix = words[cword]
		}
		return firstTokenCandidates(prefix)
	}
	if len(words) < 2 {
		return nil
	}
	first := words[1]

	// A global option that takes a value: complete the value.
	if cword == 2 && strings.HasPrefix(first, "--") {
		return optionValues(first, s, a)
	}
	if cword == 2 && first == "list" {
		return []string{"projects", "runtimes", "services", "dbs", "network"}
	}
	// Verb-first form: the second token is a project name. `create` takes
	// a NEW name, so no suggestion list applies there.
	if cword == 2 && IsProjectVerb(first) {
		if first == "create" {
			return nil
		}
		return projectNames(s)
	}
	if cword >= 3 {
		return verbArgs(first)
	}
	return nil
}

func firstTokenCandidates(prefix string) []string {
	if strings.HasPrefix(prefix, "-") {
		return globalFlags
	}
	out := append([]string{}, ProjectVerbs...)
	sort.Strings(out)
	return append(append(out, "list"), globalFlags...)
}

func optionValues(flag string, s state.Store, a assets.Tree) []string {
	switch flag {
	case "--runtime-start", "--runtime-stop", "--runtime-delete", "--runtime":
		return s.RuntimeNames()
	case "--db-start", "--db-stop", "--db-delete":
		return databaseNames(s)
	case "--db-create":
		// The DB layer accepts a bare engine (version defaulted) as well
		// as engine:version, so offer both shapes.
		return []string{"postgres", "postgres:17", "mariadb", "mariadb:10.11", "mysql", "mysql:8.4"}
	case "--runtime-create":
		return uncreatedRuntimes(s, a)
	default:
		return nil
	}
}

// verbArgs completes the flags of `mpd <verb> <project> …`.
func verbArgs(verb string) []string {
	switch verb {
	case "create":
		// No --db here: project-type knobs live in mpd.env and are set
		// through configure.
		return []string{"--type=", "--yes"}
	case "configure":
		// Commonly-set keys; any MPD_* key is accepted.
		return []string{"MPD_DB=", "MPD_PHP_VERSION=", "MPD_PHP_MOODLE_BEHAT=", "--yes"}
	case "delete":
		return []string{"--yes"}
	default:
		return nil
	}
}

func projectNames(s state.Store) []string {
	var names []string
	for _, p := range s.Projects() {
		names = append(names, p.Name)
	}
	return names
}

func databaseNames(s state.Store) []string {
	var names []string
	for _, d := range s.Databases() {
		names = append(names, d.DatabaseID)
	}
	return names
}

// uncreatedRuntimes are runtimes with an asset definition but no state
// entry — the only ones `--runtime-create` can act on.
func uncreatedRuntimes(s state.Store, a assets.Tree) []string {
	created := map[string]bool{}
	for _, n := range s.RuntimeNames() {
		created[n] = true
	}
	var out []string
	for _, n := range a.RuntimeNames() {
		if !created[n] {
			out = append(out, n)
		}
	}
	sort.Strings(out)
	return out
}

// CompleteFromArgs is the `--complete` entry point: it parses the raw
// argument list the shim passes and emits candidates.
//
// A malformed cword yields no candidates rather than an error, for the
// same reason the rest of this file swallows failures.
func CompleteFromArgs(out io.Writer, args []string, s state.Store, a assets.Tree) {
	if len(args) == 0 {
		return
	}
	cword := 0
	if _, err := fmt.Sscanf(args[0], "%d", &cword); err != nil {
		return
	}
	Complete(out, cword, args[1:], s, a)
}

// ExitCompletion ends the process cleanly after emitting candidates.
// Completion must always exit 0: a non-zero status makes some shells beep
// or print the command's stderr into the candidate list.
func ExitCompletion() { os.Exit(0) }
