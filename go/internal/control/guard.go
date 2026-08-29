// Package control lets `mpd` run from inside a runtime container by
// forwarding commands to the VM over a per-runtime Unix socket.
//
// The daemon only ever runs the mpd binary it spawns itself; a request
// chooses a verb or flag, never an executable, and a compiled-in
// denylist refuses commands that act on the VM, tear down the caller's
// runtime, or start a control-plane daemon. Caller identity comes from
// the socket the connection arrived on, never from the request, and the
// request's cwd is validated, not believed.
package control

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/cli"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
)

// Request is what an in-runtime client asks the VM to do.
type Request struct {
	// Argv is the command as typed, without the program name.
	Argv []string `json:"argv"`
	// Cwd is the client's working directory. Meaningful across the
	// boundary only because /srv is the same tree at the same path on
	// both sides.
	Cwd string `json:"cwd"`
	// Term is the caller's TERM. Untrusted input; sanitised by SafeTerm
	// before it reaches a child's environment.
	Term string `json:"term,omitempty"`
}

// SafeTerm returns Term when it looks like a terminal name, else "".
//
// The value ends up in a child process's environment, so anything
// outside the short terminfo-name alphabet is refused rather than
// trimmed.
func (r Request) SafeTerm() string {
	if r.Term == "" || len(r.Term) > 64 {
		return ""
	}
	for _, c := range r.Term {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '-', c == '_', c == '.', c == '+':
		default:
			return ""
		}
	}
	return r.Term
}

// blockedVerbs are verbs a runtime may not ask for, with the reason
// shown to the caller.
var blockedVerbs = map[string]string{
	// run would loop: runtime → VM → the same runtime.
	"run": "you are already inside the runtime — run the command directly",
}

const (
	reasonVM      = "it acts on the VM itself"
	reasonRuntime = "it would tear down the runtime you are calling from"
	reasonDaemon  = "it is a control-plane daemon started by systemd, not an interactive command"
)

// blockedFlags are the global-flag commands a runtime may not ask for.
// With a single runtime there is no other tenant to protect, so the
// fence is only around what would terminate the caller's runtime or
// start a control-plane daemon; everything else is forwarded.
// TestEveryGlobalFlagClassified pins this map against cli.GlobalFlags,
// so a new flag fails the build until classified.
var blockedFlags = map[string]string{
	"--vm-setup":   reasonVM,
	"--vm-upgrade": reasonVM,
	"--vm-start":   reasonVM,
	"--vm-stop":    reasonVM,
	"--vm-restart": reasonVM,

	"--runtime-rebuild": reasonRuntime,
	"--runtime-restore": reasonRuntime,

	"--web":     reasonDaemon,
	"--control": reasonDaemon,
}

// flagName strips any =value so --vm-stop=1 matches the same denylist
// key as --vm-stop. Non-flag arguments never match: every denied key
// begins with "--".
func flagName(arg string) string {
	name, _, _ := strings.Cut(arg, "=")
	return name
}

// AllowedVerbs returns the project verbs a runtime may ask for, sorted.
//
// Derived from cli.ProjectVerbs minus blockedVerbs, so the two cannot
// drift. A pinning test makes adding a verb a deliberate decision about
// runtime exposure.
func AllowedVerbs() []string {
	var out []string
	for _, v := range cli.ProjectVerbs {
		if _, blocked := blockedVerbs[v]; !blocked {
			out = append(out, v)
		}
	}
	sort.Strings(out)
	return out
}

// Decision is an approved request: what to run, and where.
type Decision struct {
	// Argv is the validated command line for the child mpd.
	Argv []string
	// Dir is the child's working directory: the caller's cwd when inside
	// /srv, else /srv. A path like /home/<user> exists on the VM too but
	// is a different directory there, so it must not be used.
	Dir string
}

// Guard decides whether a request from a runtime may run.
type Guard struct {
	// Runtime is the calling runtime, taken from the socket. Never from
	// the request.
	Runtime string
	State   state.Store
	Assets  assets.Tree
}

// Check validates a request and returns the argv to execute.
//
// A returned error is shown to the caller verbatim, so each one names
// what was refused and where to do it instead.
func (g Guard) Check(r Request) (Decision, error) {
	if g.Runtime == "" {
		return Decision{}, fmt.Errorf("internal error: request has no calling runtime")
	}
	if len(r.Argv) == 0 {
		return Decision{}, fmt.Errorf("no command given")
	}

	verb := r.Argv[0]
	if reason, blocked := blockedVerbs[verb]; blocked {
		return Decision{}, fmt.Errorf("mpd %s is not available from inside a runtime: %s", verb, reason)
	}

	// Refuse blocked flags anywhere in the argv, so one cannot ride
	// along on a project verb. Cobra would reject that too, but a
	// security boundary must not rest on another package's flag rules.
	for _, arg := range r.Argv {
		if reason, blocked := blockedFlags[flagName(arg)]; blocked {
			return Decision{}, fmt.Errorf(
				"mpd %s is not available from inside a runtime: %s.\n"+
					"Run it from a VM terminal instead.", flagName(arg), reason)
		}
	}

	dir, inSrv, err := g.checkCwd(r.Cwd)
	if err != nil {
		return Decision{}, err
	}
	decide := func(argv []string) Decision { return Decision{Argv: argv, Dir: dir} }

	// Non-project commands have no target project to resolve; the child
	// owns their argument parsing and any "unknown command" error.
	if !cli.IsProjectVerb(verb) {
		return decide(r.Argv), nil
	}

	// Only a cwd inside /srv can name a project: the same path outside
	// /srv is a different directory on the VM.
	name := ""
	if inSrv {
		name = targetProject(verb, r.Argv, dir)
	} else {
		name = explicitProject(verb, r.Argv)
	}
	if verb == "help" && name == "" {
		return decide(r.Argv), nil
	}
	if name == "" {
		return Decision{}, fmt.Errorf("mpd %s: no project named, and %s is not inside %s/<name>/.\n"+
			"Either name one (mpd %s <project>) or cd into its directory.",
			verb, r.Cwd, srv.Projects, verb)
	}

	// One runtime: every registered project belongs to the caller.
	if _, found := g.project(name); found {
		return decide(r.Argv), nil
	}

	// Unregistered project: only init does anything useful with that.
	// The rest fail in the child with mpd's own "not found" message.
	if verb != "init" {
		return decide(r.Argv), nil
	}
	argv, err := g.checkInitType(name, r.Argv)
	if err != nil {
		return Decision{}, err
	}
	return decide(argv), nil
}

// checkCwd validates the client's claimed working directory. It returns
// the directory the child should run in, and whether the caller's cwd
// was inside /srv.
//
// A cwd outside /srv is legitimate — SSH lands in $HOME — but unusable
// as context, so the child runs in /srv instead. A relative or unclean
// path indicates a client that is not mpd and is refused.
func (g Guard) checkCwd(cwd string) (dir string, inSrv bool, err error) {
	if cwd == "" {
		return "", false, fmt.Errorf("request has no working directory")
	}
	if !filepath.IsAbs(cwd) {
		return "", false, fmt.Errorf("working directory %q is not absolute", cwd)
	}
	if filepath.Clean(cwd) != cwd {
		return "", false, fmt.Errorf("working directory %q is not a clean path", cwd)
	}
	if cwd != srv.Dir && !strings.HasPrefix(cwd, srv.Dir+string(filepath.Separator)) {
		return srv.Dir, false, nil
	}
	return cwd, true, nil
}

// explicitProject returns the project named on the command line,
// ignoring the working directory.
func explicitProject(verb string, argv []string) string {
	for _, arg := range argv[1:] {
		if strings.HasPrefix(arg, "-") {
			continue
		}
		if verb == "start" && strings.Contains(arg, "=") {
			continue
		}
		return arg
	}
	return ""
}

// checkInitType validates a declared --type against the types the asset
// tree defines. An undeclared type is left for the child to infer.
func (g Guard) checkInitType(name string, argv []string) ([]string, error) {
	all := g.Assets.AllProjectTypes()

	if declared, ok := typeFlag(argv); ok {
		if declared == "" {
			return nil, fmt.Errorf("--type needs a value (one of: %s)", strings.Join(all, ", "))
		}
		if !g.Assets.HasProjectType(declared) {
			return nil, fmt.Errorf("unknown project type %q (one of: %s)",
				declared, strings.Join(all, ", "))
		}
	}
	return argv, nil
}

func (g Guard) project(name string) (state.Project, bool) {
	for _, p := range g.State.Projects() {
		if p.Name == name {
			return p, true
		}
	}
	return state.Project{}, false
}

// targetProject resolves which project a command is about, mirroring
// the CLI's rules: the first positional argument, else the project
// whose tree the caller is standing in. A `start` token containing `=`
// is a setting, not a name (see cli.SplitStartArgs).
func targetProject(verb string, argv []string, cwd string) string {
	if name := explicitProject(verb, argv); name != "" {
		return name
	}
	name, ok := projectFromPath(cwd)
	if !ok {
		return ""
	}
	return name
}

// projectFromPath returns the project directory name when path is
// /srv/projects/<name> or below. Deliberately not
// cli.ProjectNameFromCwd, which reads the daemon's own cwd, not the
// caller's.
func projectFromPath(path string) (string, bool) {
	prefix := srv.Projects + string(filepath.Separator)
	if !strings.HasPrefix(path, prefix) {
		return "", false
	}
	name, _, _ := strings.Cut(strings.TrimPrefix(path, prefix), string(filepath.Separator))
	if name == "" {
		return "", false
	}
	return name, true
}

// typeFlag finds a --type argument in either form.
func typeFlag(argv []string) (string, bool) {
	for i, arg := range argv {
		if value, ok := strings.CutPrefix(arg, "--type="); ok {
			return value, true
		}
		if arg == "--type" {
			if i+1 < len(argv) {
				return argv[i+1], true
			}
			return "", true
		}
	}
	return "", false
}
