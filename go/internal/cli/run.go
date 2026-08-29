package cli

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
)

// ExitError carries a child process's exit status up to main, which
// exits with it. Its message is never printed — the child already wrote
// its own stderr.
type ExitError struct{ Code int }

func (e ExitError) Error() string { return fmt.Sprintf("exit status %d", e.Code) }

// Run executes a command inside the runtime, in the caller's working
// directory (/srv is the same path on both sides). The VM-side shims
// build on it, so exit codes, stdio and TTY allocation must behave like
// the real command.
func Run(ctx context.Context, out io.Writer, d ProjectDeps, command []string) error {
	if len(command) == 0 {
		return fmt.Errorf("Usage: mpd run <command> [args...]")
	}

	entry, cwd, err := projectFromCwd(d.State, command[0])
	if err != nil {
		return err
	}
	if entry.RuntimeName == "" {
		return fmt.Errorf("Project '%s' has no runtime yet. Run: mpd start %s",
			entry.Name, entry.Name)
	}

	container := d.Observer.RuntimeContainer(entry.RuntimeName)
	if container == "" || !d.Podman.Running(ctx, container) {
		return fmt.Errorf("Runtime '%s' is not running. Run: mpd start %s",
			entry.RuntimeName, entry.Name)
	}

	options := []string{"--user", d.UID, "-w", cwd, "-i"}
	if stdinIsTerminal() {
		options = append(options, "-t")
	}

	code, err := d.Podman.ExecAttached(ctx, container, options, loginShell(cwd, command)...)
	if err != nil {
		return err
	}
	if code != 0 {
		return ExitError{Code: code}
	}
	return nil
}

// projectFromCwd resolves the registered project whose tree contains the
// working directory; it never guesses. This is not the in-runtime tools'
// walk-up-to-mpd.env rule: the registry is readable here, and a stray
// mpd.env must not impersonate a project. `what` names the forwarded
// command so errors read `php: ...`, not `mpd run: ...`.
func projectFromCwd(s state.Store, what string) (state.Project, string, error) {
	name, ok := ProjectNameFromCwd()
	if !ok {
		return state.Project{}, "", fmt.Errorf(
			"%s: not inside a project (%s/<name>/).\n"+
				"Wrong directory — or wrong terminal? Runtime commands belong in the\n"+
				"runtime: ssh <user>@<runtime>.runtime.<zone>", what, srv.Projects)
	}
	entry, found := findProject(s, name)
	if !found {
		return state.Project{}, "", fmt.Errorf(
			"%s: '%s' is not a registered project.\nRun: mpd init %s", what, name, name)
	}
	cwd, err := os.Getwd()
	if err != nil {
		return state.Project{}, "", err
	}
	// Hand the container the resolved path: a symlinked cwd on the VM
	// may not exist under that name inside.
	resolved, err := filepath.EvalSymlinks(cwd)
	if err != nil {
		resolved = filepath.Clean(cwd)
	}
	return entry, resolved, nil
}

// loginShell wraps the command so it gets an interactive session's
// environment. `podman exec` starts no shell, and the mpd tools are on
// PATH only via ~/.bashrc. The `cd` is not redundant with `-w`: that
// .bashrc ends with `cd /srv/projects`, which would relocate the
// command. `exec` keeps the child's exit status and signals ours.
func loginShell(cwd string, command []string) []string {
	args := []string{
		"bash", "-lc",
		`cd -- "$1" || exit 1; shift; exec "$@"`,
		"mpd-run", // $0, and what bash reports in any error it prints
		cwd,
	}
	return append(args, command...)
}

// stdinIsTerminal decides `podman exec -t`. Always passing -t breaks
// pipes: podman refuses a TTY when stdin is a pipe, and a TTY corrupts
// piped output with carriage returns.
func stdinIsTerminal() bool {
	info, err := os.Stdin.Stat()
	if err != nil {
		return false
	}
	return info.Mode()&os.ModeCharDevice != 0
}
