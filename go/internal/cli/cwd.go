package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/mutms/mpd/go/internal/srv"
)

// ProjectNameFromCwd returns the project whose tree contains the working
// directory (/srv/projects/<name> or below). Outside that tree it never
// guesses a project.
func ProjectNameFromCwd() (string, bool) {
	cwd, err := os.Getwd()
	if err != nil {
		return "", false
	}
	// Resolve symlinks before matching so nothing walks out of the tree.
	resolved, err := filepath.EvalSymlinks(cwd)
	if err != nil {
		resolved = filepath.Clean(cwd)
	}
	return projectNameFromPath(resolved)
}

func projectNameFromPath(path string) (string, bool) {
	prefix := srv.Projects + string(os.PathSeparator)
	if !strings.HasPrefix(path, prefix) {
		return "", false
	}
	rest := strings.TrimPrefix(path, prefix)
	name, _, _ := strings.Cut(rest, string(os.PathSeparator))
	if name == "" {
		return "", false
	}
	return name, true
}

// ProjectArg resolves a verb's project: the explicit argument when given,
// otherwise the project derived from the working directory.
func ProjectArg(verb string, args []string) (string, error) {
	if len(args) > 0 && args[0] != "" {
		return args[0], nil
	}
	if name, ok := ProjectNameFromCwd(); ok {
		return name, nil
	}
	return "", fmt.Errorf("mpd %s: no project named, and not inside %s/<name>/.\n"+
		"Either name one (mpd %s <project>) or cd into its directory.",
		verb, srv.Projects, verb)
}

// SplitStartArgs separates `mpd start`'s project name from its KEY=VALUE
// settings. A setting always contains `=` and a valid project name never
// does, so a leading token without `=` is the project; otherwise the
// project comes from the cwd.
func SplitStartArgs(args []string) (project string, settings []string, err error) {
	if len(args) > 0 && !strings.Contains(args[0], "=") {
		return args[0], args[1:], nil
	}
	name, resolveErr := ProjectArg("start", nil)
	if resolveErr != nil {
		return "", nil, resolveErr
	}
	return name, args, nil
}
