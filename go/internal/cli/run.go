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

// ExitError carries a child process's exit status up to main, which exits
// with it.
//
// A forwarded command's exit code is the whole point of forwarding: a
// shim is useless in a shell pipeline or a Makefile if every failure
// collapses to 1. Its message is never printed — the child already said
// whatever it had to say on its own stderr.
type ExitError struct{ Code int }

func (e ExitError) Error() string { return fmt.Sprintf("exit status %d", e.Code) }

// Run executes a command inside the runtime that owns the current
// project.
//
// The command runs with the caller's working directory, which is correct
// verbatim rather than by translation: /srv is the same tree at the same
// path on the VM and inside every container, so /srv/projects/moodle45
// means the same thing on both sides.
//
// This is the mechanism behind the VM-side shims — `php` on the VM is a
// two-line script that execs `mpd run -- php "$@"` — so its ergonomics
// are load-bearing: exit codes propagate, stdin/stdout/stderr are the
// caller's, and a TTY is allocated when the caller has one.
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

// projectFromCwd resolves the project whose tree the caller is standing
// in.
//
// The rule is deliberately narrow: the working directory must be
// /srv/projects/<name> or below, and <name> must be a registered project.
// Nothing else is a project context, and guessing one — the only runtime,
// the last one used — would run a command somewhere the caller did not
// ask for.
//
// This is NOT the rule the in-runtime tools use (walk up to mpd.env, take
// the basename). They use that because a runtime container cannot read
// projects.json; the state directory is not mounted into it. On the VM
// the registry is right here, so a path check is both cheaper and safer:
// a stray mpd.env elsewhere on the VM cannot impersonate a project, and a
// project whose mpd.env is missing or not yet written still resolves.
//
// `what` names the command being forwarded, so an error reads `php: not
// inside a project` rather than `mpd run: ...` — the caller typed the
// shim, not this.
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
	// The container is handed the resolved path: /srv is a bind mount, so
	// a symlinked cwd on the VM may not exist under that name inside.
	resolved, err := filepath.EvalSymlinks(cwd)
	if err != nil {
		resolved = filepath.Clean(cwd)
	}
	return entry, resolved, nil
}

// loginShell wraps the command so it runs with the environment an
// interactive runtime session gets.
//
// `podman exec` starts no shell, so it inherits only the container's bare
// PATH — /usr/bin and friends. Every mpd tool (mdl-install, phpunit,
// composer-install, the php wrapper) is on PATH courtesy of the home
// ~/.bashrc, which reads them out of the assets tree. Without a login
// shell `mpd run mdl-install` fails with "executable file not found",
// while `mpd run php` happens to work only because build.sh also
// symlinks php into /usr/local/bin. Forwarding a command that behaves
// differently from the same command typed in the runtime would be a trap.
//
// The `cd` is not redundant with `-w`: that same .bashrc ends with
// `cd /srv/projects` for interactive convenience, which would otherwise
// silently relocate the command. We set the directory again after the
// shell has finished initialising, and `exec` keeps the child's exit
// status and signals ours.
func loginShell(cwd string, command []string) []string {
	args := []string{
		"bash", "-lc",
		`cd -- "$1" || exit 1; shift; exec "$@"`,
		"mpd-run", // $0, and what bash reports in any error it prints
		cwd,
	}
	return append(args, command...)
}

// stdinIsTerminal reports whether stdin is a character device, which is
// what decides `podman exec -t`.
//
// Asking rather than always passing -t: podman refuses to allocate a TTY
// when stdin is a pipe, so `echo x | php -r ...` would fail outright, and
// a TTY would also corrupt piped output with carriage returns.
func stdinIsTerminal() bool {
	info, err := os.Stdin.Stat()
	if err != nil {
		return false
	}
	return info.Mode()&os.ModeCharDevice != 0
}
