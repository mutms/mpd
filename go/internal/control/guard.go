// Package control lets `mpd` be used from inside a runtime container.
//
// The runtime has the mpd binary — /opt/mpd is bind-mounted RO at the same
// path — but not the control plane: /var/lib/mpd/conf and
// /var/lib/mpd/state are deliberately absent, and there is no podman
// socket. So an in-runtime `mpd` forwards the command to the VM over a
// Unix socket and the VM does the work.
//
// # What the VM will and will not do
//
// The daemon never runs a program named in a request. It validates the
// argv against a closed, compiled-in vocabulary and then spawns the mpd
// binary itself; the request chooses a verb, never an executable.
//
// # Identity comes from the channel
//
// Each runtime gets its own socket, mounted only into that runtime, so the
// caller's identity is the socket that accepted the connection — a fact no
// client can forge. SO_PEERCRED cannot do this job: every runtime runs the
// same UID-matched dev user, so peer credentials cannot tell php from
// node.
//
// Context is treated the same way. The cwd in a request is validated, not
// believed: most verbs infer their target project from the working
// directory, so a cwd taken on faith is a way to name someone else's
// project.
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
	// Argv is the command as typed, without the program name:
	// ["create", "moodle45", "--type=moodle"].
	Argv []string `json:"argv"`
	// Cwd is the client's working directory. Meaningful across the
	// boundary only because /srv is the same tree at the same path on the
	// VM and inside every container.
	Cwd string `json:"cwd"`
	// Term is the caller's TERM, forwarded so the child renders colour the
	// way the caller's terminal expects. Sanitised before use: it reaches
	// the child's environment, so it is treated as untrusted input like
	// everything else in a request.
	Term string `json:"term,omitempty"`
}

// SafeTerm returns Term when it looks like a terminal name, else "".
//
// A TERM value ends up in a child process's environment. Nothing in mpd
// interprets it as a path or a command, so this is not an execution
// vector, but an unbounded attacker-chosen environment variable is not
// worth carrying either. Terminfo names are short and use a small
// alphabet, so anything else is refused rather than trimmed.
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

// blockedVerb is a verb that exists but must not be reachable from a
// runtime, with the reason shown to the caller.
var blockedVerbs = map[string]string{
	// run would loop: runtime → VM → the same runtime.
	"run": "you are already inside the runtime — run the command directly",
}

// AllowedVerbs returns the verbs a runtime may ask for, sorted.
//
// Derived from cli.ProjectVerbs rather than copied, so the two cannot
// drift. Project verbs are exactly the right set: everything else in the
// CLI is a global flag acting on the VM or its infrastructure, which is
// not a runtime's business. A pinning test guards the derivation, so
// adding a verb forces a deliberate decision about runtime exposure
// instead of granting it silently.
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
	// Dir is the child's working directory.
	//
	// The caller's own cwd when that is inside /srv — the one tree at the
	// same path on both sides, so it means the same thing to the child.
	// Otherwise /srv, because a path like /home/<user> exists on the VM as
	// well but is a *different* directory there, and running in the VM's
	// copy of it would be quietly wrong rather than loudly wrong.
	Dir string
}

// Guard decides whether a request from a runtime may run, and returns the
// argv to hand the child process.
type Guard struct {
	// Runtime is the calling runtime, taken from the socket. Never from
	// the request.
	Runtime string
	State   state.Store
	Assets  assets.Tree
}

// Check validates a request and returns the argv to execute.
//
// A returned error is shown to the caller verbatim, so each one names both
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
	if !cli.IsProjectVerb(verb) {
		return Decision{}, fmt.Errorf(
			"only project commands work from inside a runtime; %q is not one.\n"+
				"Available here: %s.\n"+
				"Anything acting on the VM, a runtime or a database belongs in a VM terminal.",
			verb, strings.Join(AllowedVerbs(), ", "))
	}

	// Defence in depth. Cobra does not inherit the root command's
	// non-persistent flags into subcommands, so `mpd create x --vm-setup`
	// would already fail as an unknown flag — but a security boundary
	// should not rest on another package's flag-inheritance rules.
	for _, arg := range r.Argv[1:] {
		for _, prefix := range []string{"--vm-", "--runtime-", "--db-"} {
			if strings.HasPrefix(arg, prefix) {
				return Decision{}, fmt.Errorf(
					"%s flags are not available from inside a runtime (%s)", prefix, arg)
			}
		}
	}

	dir, inSrv, err := g.checkCwd(r.Cwd)
	if err != nil {
		return Decision{}, err
	}
	decide := func(argv []string) Decision { return Decision{Argv: argv, Dir: dir} }

	// `help` prints text and touches nothing. With no project argument it
	// prints the general help, so there is no target to cross-check.
	//
	// Only a cwd inside /srv can name a project. Outside it, inference is
	// not merely refused, it is meaningless: the same path on the VM is a
	// different directory.
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

	if project, found := g.project(name); found {
		// A project keeps runtimeName empty until it is configured, so an
		// unconfigured one has to be judged by its type instead. Without
		// this, `mpd configure` on a scaffolded moodle project would be
		// allowed from the node runtime and would then provision php — the
		// exact cross-runtime provisioning the scoping rule exists to stop.
		owner := project.RuntimeName
		how := "belongs to"
		if owner == "" {
			if byType, ok := g.Assets.DefaultRuntimeForType(project.Type); ok {
				owner = byType
				how = "is a '" + project.Type + "' project, which runs on"
			}
		}
		if owner != "" && owner != g.Runtime {
			return Decision{}, fmt.Errorf(
				"cannot act on project '%s' from the '%s' runtime — it %s '%s'.\n"+
					"Run it from a VM terminal, or from that runtime.",
				name, g.Runtime, how, owner)
		}
		return decide(r.Argv), nil
	}

	// Not a registered project. Only `create` does anything useful with
	// that; the rest are left to fail in the child with mpd's own
	// "not found" message rather than a second, differently-worded one.
	if verb != "create" {
		return decide(r.Argv), nil
	}
	argv, err := g.checkCreateType(name, r.Argv)
	if err != nil {
		return Decision{}, err
	}
	return decide(argv), nil
}

// checkCwd validates the client's claimed working directory and reports
// where the child should run.
//
// Returns the directory to use, and whether the caller's cwd was inside
// /srv — which is what decides if cwd may name a project.
//
// A cwd outside /srv is not an error. When you SSH into a runtime you land
// in $HOME, so refusing there would fail the first command anyone types,
// even one that names its project explicitly and has no use for cwd. It is
// simply not usable as context: /home/<user> exists on the VM too, but it
// is a *different* directory, so the child runs in /srv instead of quietly
// operating in the VM's copy.
//
// What is rejected is a path that is malformed rather than merely
// elsewhere: relative, or not lexically clean. Those indicate a client that
// is not mpd, and `..` is how a claimed path would try to reach out of the
// tree it appears to be in.
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

// explicitProject returns the project named on the command line, ignoring
// the working directory. Used when cwd cannot name a project.
func explicitProject(verb string, argv []string) string {
	for _, arg := range argv[1:] {
		if strings.HasPrefix(arg, "-") {
			continue
		}
		if verb == "configure" && strings.Contains(arg, "=") {
			continue
		}
		return arg
	}
	return ""
}

// checkCreateType constrains `create` to project types belonging to the
// calling runtime, and fills the type in when there is only one.
//
// On the VM the type determines the runtime: create resolves it through
// DefaultRuntimeForType and provisions whatever that names. From inside a
// runtime that would be backwards — the runtime is a given, so an
// unconstrained type would quietly build a *second* runtime on the caller's
// behalf. Here the type must fit the caller instead of choosing for it.
func (g Guard) checkCreateType(name string, argv []string) ([]string, error) {
	mine := g.myTypes()

	if declared, ok := typeFlag(argv); ok {
		if declared == "" {
			return nil, fmt.Errorf("--type needs a value (one of: %s)", strings.Join(mine, ", "))
		}
		owner, known := g.Assets.DefaultRuntimeForType(declared)
		if !known {
			return nil, fmt.Errorf("unknown project type %q", declared)
		}
		if owner != g.Runtime {
			return nil, fmt.Errorf(
				"project type '%s' runs on the '%s' runtime, but you are in '%s'.\n"+
					"Create it from a VM terminal, or pick a type this runtime serves: %s.",
				declared, owner, g.Runtime, strings.Join(mine, ", "))
		}
		return argv, nil
	}

	// No --type. The child would infer one from the name, and inference
	// searches every runtime's types — so it can reach past the caller.
	// Resolve it here instead of letting that happen.
	if inferred := g.Assets.DetectTypeFromName(name); inferred != "" {
		owner, known := g.Assets.DefaultRuntimeForType(inferred)
		if known && owner != g.Runtime {
			return nil, fmt.Errorf(
				"the name '%s' implies project type '%s', which runs on the '%s' runtime, "+
					"but you are in '%s'.\n"+
					"Pass --type explicitly (one of: %s), or create it from a VM terminal.",
				name, inferred, owner, g.Runtime, strings.Join(mine, ", "))
		}
		if known {
			return argv, nil
		}
	}

	// Nothing inferred. One type means no ambiguity, so supply it rather
	// than making the caller name the only possible answer; several means
	// the caller has to choose, because mpd's own fallback default may
	// belong to another runtime entirely.
	switch len(mine) {
	case 0:
		return nil, fmt.Errorf("the '%s' runtime has no project types", g.Runtime)
	case 1:
		return append(append([]string{}, argv...), "--type="+mine[0]), nil
	default:
		return nil, fmt.Errorf(
			"mpd create: which type? The '%s' runtime serves: %s.\n"+
				"Pass one, e.g. mpd create %s --type=%s",
			g.Runtime, strings.Join(mine, ", "), name, mine[0])
	}
}

// myTypes lists the project types the calling runtime serves, sorted.
func (g Guard) myTypes() []string {
	var mine []string
	for _, t := range g.Assets.AllProjectTypes() {
		if owner, ok := g.Assets.DefaultRuntimeForType(t); ok && owner == g.Runtime {
			mine = append(mine, t)
		}
	}
	sort.Strings(mine)
	return mine
}

func (g Guard) project(name string) (state.Project, bool) {
	for _, p := range g.State.Projects() {
		if p.Name == name {
			return p, true
		}
	}
	return state.Project{}, false
}

// targetProject resolves which project a command is about, mirroring the
// CLI's own rules: the first positional argument after the verb, else the
// project whose tree the caller is standing in.
//
// Returns "" when neither applies. `configure` takes KEY=VALUE settings in
// the same positional slot, so a token containing `=` is a setting and not
// a name (see cli.SplitConfigureArgs).
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
// /srv/projects/<name> or below.
//
// Deliberately not cli.ProjectNameFromCwd: that reads this process's own
// working directory, which on the daemon side is the daemon's, not the
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
