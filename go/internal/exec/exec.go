// Package exec is mpd's single gateway for running external processes.
//
// It is the ONLY package that imports os/exec. Every other package that
// needs a subprocess builds a domain wrapper on top of this one — most
// notably internal/podman. AGENTS.md states this as a mandatory
// constraint: direct host-OS command execution is allowed only here.
//
// # Difference from mudev's internal/exec
//
// mudev resolves commands with exec.LookPath. mpd deliberately does not:
// it runs privileged operations on the VM, so every executable is pinned
// to an absolute path in an allow-list (see binaries below). A command
// that is not on the list cannot be run at all, and a PATH manipulation
// cannot redirect one that is. Keep that property — it is the reason this
// package exists rather than callers using os/exec directly, and it is
// what AGENTS.md means by "direct host-OS command execution is allowed
// only here".
package exec

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	osexec "os/exec"
	"strings"
)

// ExitNotPermitted is returned as the exit code when a command is not on
// the allow-list. 127 is the shell's "command not found", which is the
// closest existing convention for "mpd will not run that".
const ExitNotPermitted = 127

// binaries maps a bare command name to its absolute path. Adding an entry
// is a deliberate act: it widens what mpd is able to execute.
var binaries = map[string]string{
	"apt-get":  "/usr/bin/apt-get",
	"bash":     "/bin/bash",
	"certutil": "/usr/bin/certutil",
	"cp":       "/bin/cp",
	"git":      "/usr/bin/git",
	"id":       "/usr/bin/id",
	"install":  "/usr/bin/install",
	"ip":       "/usr/sbin/ip",
	"loginctl": "/usr/bin/loginctl",
	"make":     "/usr/bin/make",
	// mpd itself, so `--vm-upgrade` can apply the binary it just built
	// rather than the one it is running.
	"mpd":                    "/opt/mpd/bin/mpd",
	"mv":                     "/usr/bin/mv",
	"nft":                    "/usr/sbin/nft",
	"openssl":                "/usr/bin/openssl",
	"ping":                   "/usr/bin/ping",
	"podman":                 "/usr/bin/podman",
	"rm":                     "/usr/bin/rm",
	"sha256sum":              "/usr/bin/sha256sum",
	"ssh-keygen":             "/usr/bin/ssh-keygen",
	"sudo":                   "/usr/bin/sudo",
	"systemctl":              "/usr/bin/systemctl",
	"update-ca-certificates": "/usr/sbin/update-ca-certificates",
	"whoami":                 "/usr/bin/whoami",
}

// Cmd describes one external command.
type Cmd struct {
	// Name is a bare command name; it must be on the allow-list.
	Name string
	Args []string
	// Dir is the working directory; empty means the current directory.
	Dir string
	// Env holds extra "KEY=VALUE" entries appended to os.Environ().
	Env []string
	// Stdin is optional standard input.
	Stdin io.Reader
	// Stdout and Stderr are where Run sends the command's output. Nil
	// means this process's own os.Stdout / os.Stderr, which is what every
	// caller on the VM wants.
	//
	// They exist for callers that are not the process's own terminal. When
	// mpd serves a request from inside a runtime, the command's output has
	// to reach the caller's terminal rather than the daemon's journal, and
	// output produced by children — asset scripts, podman — is most of what
	// a verb like `create` prints. Since this package is the only one
	// allowed to start a process, nothing else can redirect it.
	//
	// Passing an *os.File matters: os/exec hands a real file descriptor
	// straight to the child, so the child sees a genuine (possibly tty)
	// descriptor and writes to it unbuffered. Any other io.Writer gets a
	// pipe plus a copying goroutine, which works but loses the tty.
	//
	// Capture ignores both — capturing output is its entire contract.
	Stdout io.Writer
	Stderr io.Writer
	// Sudo runs the command via `sudo -n`. Non-interactive on purpose:
	// mpd never prompts for a password, it fails and says what to fix.
	Sudo bool
}

// Result is the outcome of a captured command.
type Result struct {
	Code   int
	Stdout string
	Stderr string
}

// Failed reports whether the command exited non-zero.
func (r Result) Failed() bool { return r.Code != 0 }

// Err converts a non-zero exit into an error, folding in stderr. Callers
// that inspect specific exit codes should read Code directly.
func (r Result) Err() error {
	if r.Code == 0 {
		return nil
	}
	if r.Stderr != "" {
		return fmt.Errorf("exit status %d: %s", r.Code, r.Stderr)
	}
	return fmt.Errorf("exit status %d", r.Code)
}

// Path returns the absolute path for an allow-listed command name.
func Path(name string) (string, bool) {
	p, ok := binaries[name]
	return p, ok
}

// Names lists every allow-listed command name, for preflight checks.
func Names() []string {
	out := make([]string, 0, len(binaries))
	for name := range binaries {
		out = append(out, name)
	}
	return out
}

// Available reports whether the named command is allow-listed AND present
// and executable on this machine.
func Available(name string) bool {
	p, ok := binaries[name]
	if !ok {
		return false
	}
	info, err := os.Stat(p)
	if err != nil || info.IsDir() {
		return false
	}
	return info.Mode().Perm()&0o111 != 0
}

// Run executes cmd, streaming stdout and stderr to cmd.Stdout and
// cmd.Stderr — this process's own when they are nil.
// It returns the exit code. A non-zero exit is not an error: err is
// non-nil only when the process could not be started, or when the command
// is not allow-listed (code ExitNotPermitted).
func Run(ctx context.Context, cmd Cmd) (int, error) {
	c, err := build(ctx, cmd)
	if err != nil {
		return ExitNotPermitted, err
	}
	c.Stdout = writerOr(cmd.Stdout, os.Stdout)
	c.Stderr = writerOr(cmd.Stderr, os.Stderr)
	return wait(c)
}

// writerOr returns w, or fallback when w is nil.
//
// Written out rather than inlined because a typed-nil io.Writer is not
// == nil, and assigning one to osexec.Cmd.Stdout makes the child's output
// vanish silently. Callers build Cmd from many places; funnelling the
// choice through one func keeps that trap in a single spot.
func writerOr(w io.Writer, fallback io.Writer) io.Writer {
	if w == nil {
		return fallback
	}
	return w
}

// Capture executes cmd and captures stdout and stderr separately, with
// trailing newlines trimmed. Same error contract as Run.
func Capture(ctx context.Context, cmd Cmd) (Result, error) {
	c, err := build(ctx, cmd)
	if err != nil {
		return Result{Code: ExitNotPermitted}, err
	}
	var stdout, stderr bytes.Buffer
	c.Stdout = &stdout
	c.Stderr = &stderr
	code, runErr := wait(c)
	return Result{
		Code:   code,
		Stdout: strings.TrimRight(stdout.String(), "\n"),
		Stderr: strings.TrimRight(stderr.String(), "\n"),
	}, runErr
}

func build(ctx context.Context, cmd Cmd) (*osexec.Cmd, error) {
	path, ok := binaries[cmd.Name]
	if !ok {
		return nil, fmt.Errorf("command %q is not allow-listed in internal/exec", cmd.Name)
	}

	name, args := path, cmd.Args
	if cmd.Sudo {
		sudo, ok := binaries["sudo"]
		if !ok {
			return nil, fmt.Errorf("sudo is not allow-listed in internal/exec")
		}
		name = sudo
		args = append([]string{"-n", path}, cmd.Args...)
	}

	c := osexec.CommandContext(ctx, name, args...)
	c.Dir = cmd.Dir
	if len(cmd.Env) > 0 {
		c.Env = append(os.Environ(), cmd.Env...)
	}
	if cmd.Stdin != nil {
		c.Stdin = cmd.Stdin
	}
	return c, nil
}

func wait(c *osexec.Cmd) (int, error) {
	if err := c.Run(); err != nil {
		var ee *osexec.ExitError
		if ok := asExitError(err, &ee); ok {
			return ee.ExitCode(), nil
		}
		return -1, err
	}
	return 0, nil
}

// asExitError is errors.As specialised to *osexec.ExitError, kept
// separate so the intent reads clearly at the call site.
func asExitError(err error, target **osexec.ExitError) bool {
	ee, ok := err.(*osexec.ExitError)
	if ok {
		*target = ee
	}
	return ok
}
