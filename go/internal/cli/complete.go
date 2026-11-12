package cli

import (
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/service"
	"github.com/mutms/mpd/go/internal/state"
)

// Shell completion candidates for bash and zsh; the shims under
// assets/completions/ call `mpd --complete <cword> <word0> …`.
// Every Tab press forks mpd: keep this path to state-file reads and
// directory listings — no podman calls, no network.

// ProjectVerbs are the tokens accepted as the first positional argument.
// They are reserved as project names, so a project can never collide with
// a verb.
var ProjectVerbs = []string{"delete", "help", "init", "reset", "run", "start", "status", "stop"}

// IsProjectVerb reports whether a token is a project verb.
func IsProjectVerb(token string) bool {
	for _, v := range ProjectVerbs {
		if v == token {
			return true
		}
	}
	return false
}

// GlobalFlags is every long flag mpd accepts. It mirrors the flag set in
// cmd/mpd/main.go — add new entries in both places.
var GlobalFlags = []string{
	"--vm-setup",
	"--vm-upgrade",
	"--vm-start",
	"--vm-stop",
	"--vm-restart",
	"--service-start",
	"--service-stop",
	"--service-uninstall",
	"--service-purge",
	"--db-create",
	"--db-start",
	"--db-stop",
	"--db-delete",
	"--vm-status",
	"--vm-diag",
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
	if cword == 2 && (first == "list" || first == "ls") {
		return []string{"projects", "services", "infra", "dbs", "network"}
	}
	// The second token is a project name. `init` takes a new name, so
	// nothing is suggested there.
	if cword == 2 && (IsProjectVerb(first) || first == "rm") {
		if first == "init" {
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
		return GlobalFlags
	}
	out := append([]string{}, ProjectVerbs...)
	sort.Strings(out)
	// "ls" and "rm" are aliases for "list" and "delete".
	return append(append(out, "list", "ls", "rm"), GlobalFlags...)
}

func optionValues(flag string, s state.Store, a assets.Tree) []string {
	switch flag {
	case "--db-start", "--db-stop", "--db-delete":
		return databaseNames(s)
	case "--db-create":
		// The DB layer accepts a bare engine or engine:version; offer both.
		return []string{"postgres", "postgres:17", "mariadb", "mariadb:10.11", "mysql", "mysql:8.4"}
	case "--service-start", "--service-stop", "--service-uninstall", "--service-purge":
		return service.Names()
	default:
		return nil
	}
}

// verbArgs completes the flags of `mpd <verb> <project> …`.
func verbArgs(verb string) []string {
	switch verb {
	case "init":
		// No --db here: project-type knobs live in mpd.env, set via start.
		return []string{"--type=", "--yes"}
	case "start":
		// Commonly-set keys; any MPD_* key is accepted.
		return []string{"MPD_DB=", "MPD_PHP_VERSION=", "MPD_MOODLE_BEHAT="}
	case "delete", "rm", "reset":
		return []string{"--yes"}
	case "status":
		return []string{"--json"}
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

// CompleteFromArgs is the `--complete` entry point: it parses the shim's
// raw argument list and emits candidates. A malformed cword yields no
// candidates rather than an error.
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
