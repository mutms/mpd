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
// The daemon never runs a program named in a request. It refuses a
// small, compiled-in denylist and forwards everything else to the mpd
// binary it spawns itself; the request chooses a verb or flag, never an
// executable. With a single runtime there is no other tenant to isolate,
// so the boundary is a denylist of the genuinely dangerous — commands
// that act on the VM, tear down the runtime the caller is standing in,
// or drive a control-plane daemon — rather than an allowlist of project
// verbs. db and service management, project verbs, `--runtime-backup`,
// `list` and `version` all pass.
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
	// ["init", "moodle45", "--type=moodle"].
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

const (
	reasonVM      = "it acts on the VM itself"
	reasonRuntime = "it would tear down the runtime you are calling from"
	reasonDaemon  = "it is a control-plane daemon started by systemd, not an interactive command"
)

// blockedFlags are the global-flag commands a runtime may NOT ask for,
// each with the reason shown to the caller. Everything not listed —
// project verbs, --db-*, --service-* (deletes and purges included),
// --runtime-backup, the read-only --vm-status, list, and the
// --yes/--debug/--help modifiers — is forwarded: with a
// single runtime there is no other tenant to protect, so the fence is
// only around what would terminate the runtime the caller is standing in
// (directly, or by stopping/rebuilding the VM under it) or start a
// control-plane daemon that would hang or conflict.
//
// A pinning test (TestEveryGlobalFlagClassified) cross-checks this map
// against cli.GlobalFlags, so a newly added flag cannot reach a runtime
// silently: it fails the build until classified here or in that test's
// allowed set.
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

// flagName strips any =value so a flag matches its denylist key whether
// written --vm-stop or (hypothetically) --vm-stop=1. A non-flag argument
// — a project name, a KEY=VALUE start setting — never matches,
// because every denied entry begins with "--".
func flagName(arg string) string {
	name, _, _ := strings.Cut(arg, "=")
	return name
}

// AllowedVerbs returns the project verbs a runtime may ask for, sorted.
//
// Derived from cli.ProjectVerbs rather than copied, so the two cannot
// drift, minus blockedVerbs. Global-flag commands are gated separately
// (blockedFlags), so this is the project-verb slice specifically — used
// by the pinning test that keeps adding a verb a deliberate decision
// about runtime exposure rather than a silent grant.
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

	// Denylist. A handful of global-flag commands act on the VM, the
	// runtime container itself, or a control-plane daemon; refuse those
	// wherever they appear in the argv, so one cannot ride along on a
	// project verb (`mpd start x --vm-stop`) either. Cobra would already
	// reject that combination as an unknown flag, but a security boundary
	// should not rest on another package's flag-inheritance rules.
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

	// A global-flag command (--db-*, --service-*, --runtime-backup) or a
	// non-project verb (list, version) is not project-scoped: there is no
	// target project to resolve, so hand it straight to the child, which
	// owns both the argument parsing and the "unknown command" error for
	// anything bogus. Only project verbs get the target cross-check below.
	if !cli.IsProjectVerb(verb) {
		return decide(r.Argv), nil
	}

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

	// There is one runtime, so every registered project belongs to the
	// caller — no cross-runtime ownership to check any more.
	if _, found := g.project(name); found {
		return decide(r.Argv), nil
	}

	// Not a registered project. Only `init` does anything useful with
	// that; the rest are left to fail in the child with mpd's own
	// "not found" message rather than a second, differently-worded one.
	if verb != "init" {
		return decide(r.Argv), nil
	}
	argv, err := g.checkInitType(name, r.Argv)
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
		if verb == "start" && strings.Contains(arg, "=") {
			continue
		}
		return arg
	}
	return ""
}

// checkInitType validates a declared `--type` against the types the
// asset tree actually defines. With a single runtime there is no
// ownership to enforce any more — an undeclared type is left for the
// child to infer (name match, else the moodle default), same as on the
// VM.
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

// targetProject resolves which project a command is about, mirroring the
// CLI's own rules: the first positional argument after the verb, else the
// project whose tree the caller is standing in.
//
// Returns "" when neither applies. `start` takes KEY=VALUE settings in
// the same positional slot, so a token containing `=` is a setting and not
// a name (see cli.SplitStartArgs).
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
