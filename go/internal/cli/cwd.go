package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/mutms/mpd/go/internal/srv"
)

// ProjectNameFromCwd returns the project whose tree the caller is
// standing in: the working directory must be /srv/projects/<name> or any
// directory below it.
//
// Subdirectories count, which is the point — you are usually deep inside
// a source tree when you want to act on the project, not at its root.
//
// The rule is narrow on purpose. Anywhere outside that tree there is no
// project, and inferring one — the only project, the last one used —
// would act on something the caller never named.
func ProjectNameFromCwd() (string, bool) {
	cwd, err := os.Getwd()
	if err != nil {
		return "", false
	}
	// Resolve symlinks before matching: /srv is itself a bind mount, and
	// neither a symlink nor a `..` segment may walk out of the tree.
	resolved, err := filepath.EvalSymlinks(cwd)
	if err != nil {
		resolved = filepath.Clean(cwd)
	}
	return projectNameFromPath(resolved)
}

// projectNameFromPath returns the project directory name when path is
// /srv/projects/<name> or below.
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

// ProjectArg resolves a verb's project: the explicit argument when one is
// given, otherwise the directory the caller is standing in.
//
// An explicit name always wins, so a habit of naming projects keeps
// working unchanged and a script is never at the mercy of its working
// directory.
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
// settings.
//
// Both are positional, and the project may be omitted, so something has
// to tell them apart: a setting always contains `=`, and a project name
// never can (validProjectName allows lowercase letters, digits and
// internal dashes). So a leading token with no `=` is the project, and
// anything else means every token is a setting and the project comes
// from the cwd.
//
//	mpd start moodle45 MPD_DB=postgres:18   → explicit project
//	mpd start MPD_DB=postgres:18            → project from cwd
//	mpd start                               → project from cwd, no changes
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
