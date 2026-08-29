// Package hooks dispatches mpd's typed lifecycle events to bash scripts
// in the asset tree.
//
// Three nouns, no overlap (docs/hooks.md):
//
//   - **Event** — a typed moment in a lifecycle (project-pre-start).
//     Declared in Go; the catalogue is closed.
//   - **Hook** — a `*.sh` script under `hooks/<event-name>.d/` in the
//     assets, run inside a container. Written by anyone.
//   - **Audience** — which containers an event fires into. Per-event and
//     not guessable: project-pre-start fires on the project's *database*,
//     project-pre-stop on its *runtime*.
//
// This is a public contract. Scripts outside this repo depend on the
// event names, the MPD_HOOK_* environment, and the ordering, so none of
// those may drift during the port.
package hooks

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/podman"
)

// AssetsDir is the bind-mounted asset tree, identical on the VM and
// inside every container — which is what lets a host-side directory scan
// produce a path the container can execute.
const AssetsDir = "/opt/mpd/assets"

// assetsDir is the path discovery actually reads. A variable, not the
// constant, so tests can point it at a fixture tree.
var assetsDir = AssetsDir

// DefaultTimeout bounds a hook script that declares none.
//
// CAVEAT, verified rather than assumed: killing `podman exec` does NOT
// kill the process inside the container. A timed-out hook stops blocking
// mpd — which is the point — but its script keeps running in the
// container until it finishes or the container stops.
const DefaultTimeout = 30 * time.Second

// StopTimeout bounds mpd-pre-stop, where a database flushing pending IO
// legitimately takes longer than a normal hook.
const StopTimeout = 120 * time.Second

// SetupTimeout bounds mpd-post-setup. Setup hooks install things — the
// shipped ones unpack multi-gigabyte IDE tarballs — and a limit that cuts
// one off mid-unpack would be worse than no limit, because the hook keeps
// running inside its container regardless (see DefaultTimeout's caveat).
const SetupTimeout = 10 * time.Minute

// AudienceKind selects which containers an event fires into.
type AudienceKind int

const (
	// AudienceRuntime: the project's runtime container.
	AudienceRuntime AudienceKind = iota
	// AudienceDatabase: the project's database container.
	AudienceDatabase
	// AudienceService: a named always-on service container.
	AudienceService
	// AudienceVM: the VM itself, not a container. Its hooks run as the
	// dev user on the VM host, from assets/vm/hooks/<event>.d/. The one
	// audience that is not a container, because some work has no
	// container to do it in — installing something onto the VM, touching
	// a systemd unit, reading a path containers never see.
	AudienceVM
)

// VMTarget is the name printed for AudienceVM in hook output, where the
// other audiences print a container name. Not a container: nothing looks
// it up, and the dispatcher never passes it to podman.
const VMTarget = "vm"

// FailureMode decides what a failing hook does to the firing verb.
type FailureMode int

const (
	// Abort: hook failure fails the verb. For preconditions — "ensure
	// the DB is migrated before the project starts".
	Abort FailureMode = iota
	// Continue: hook failure is logged and the verb proceeds. For
	// cleanup and post-state events: you cannot fail to stop.
	Continue
)

// Event is one typed lifecycle moment.
type Event struct {
	// Name is the kebab-case event name, matching the `<name>.d`
	// directory. e.g. "project-pre-start".
	Name string
	// Revision is surfaced as MPD_HOOK_REVISION so a hook can tell which
	// contract it is being called under.
	Revision int
	// Timeout bounds each script. Zero means DefaultTimeout.
	Timeout time.Duration
	// Audiences the event fires into, in order.
	Audiences []AudienceKind
	// OnFailure decides whether a failing hook aborts the verb.
	OnFailure FailureMode
	// Env holds event-specific values, exported as MPD_HOOK_<KEY>.
	Env map[string]string
	// Containers resolves an audience to the containers to fire into.
	// Returning none is normal: a project with no database has nothing
	// to fire a database-audience event into.
	Containers func(AudienceKind) []string
	// ServiceName scopes AudienceService to one service's assets.
	ServiceName string
	// User is the identity runtime hooks run as. Empty means the
	// container's default, which is root.
	//
	// Applied to AudienceRuntime only, and that is the whole point: a
	// runtime is a host with a dev user and passwordless sudo, where
	// AGENTS.md's privilege rule says every asset script runs as that
	// user and sudo's the individual privileged commands. Database and
	// service containers are stock images with no such user — their
	// hooks signal PID 1 and must stay root.
	User string
}

// Fire runs every hook for an event, honouring its failure mode.
//
// Ordering matters and is part of the contract: audiences in declared
// order, containers within an audience, then scripts by layer
// (base → runtime → type) and alphabetically within a layer, which is
// what makes numeric prefixes (10-, 90-) meaningful.
func Fire(ctx context.Context, out io.Writer, ev Event, verb string, p *podman.Client) error {
	var aborted error

	for _, audience := range ev.Audiences {
		for _, container := range ev.targets(audience) {
			err := fireOne(ctx, out, ev, audience, container, verb, p)
			if err == nil {
				continue
			}
			if ev.OnFailure == Abort {
				aborted = err
				break
			}
			// Continue mode: fireOne already reported the failure.
		}
		if aborted != nil {
			break
		}
	}
	return aborted
}

// targets resolves an audience to the things to fire into. Containers
// for every audience but AudienceVM, which is always the one VM this mpd
// runs on — asking the event for that would let an event author get it
// wrong, and there is only one right answer.
func (ev Event) targets(a AudienceKind) []string {
	if a == AudienceVM {
		return []string{VMTarget}
	}
	return ev.Containers(a)
}

func fireOne(ctx context.Context, out io.Writer, ev Event, audience AudienceKind,
	container, verb string, p *podman.Client) error {

	scripts := discover(ctx, p, ev, audience, container)
	if len(scripts) == 0 {
		return nil
	}

	env := hookEnv(ev, verb)
	opts := execOptions(ev, audience, env)
	envList := hookEnvList(ev, verb)

	timeout := ev.Timeout
	if timeout == 0 {
		timeout = DefaultTimeout
	}

	for _, script := range scripts {
		label := fmt.Sprintf("[%s] %s/%s", container, ev.Name, script.Basename)
		started := time.Now()

		// Enforced, not merely declared: a hook that never returns would
		// otherwise hang the verb that fired it — and for mpd-pre-stop,
		// hang VM shutdown.
		runCtx, cancel := context.WithTimeout(ctx, timeout)
		var code int
		var err error
		if audience == AudienceVM {
			// Same shape as the podman path: bash runs the script, the
			// MPD_HOOK_* values are the environment, output streams to
			// the terminal. Only the executor differs.
			code, err = exec.Run(runCtx, exec.Cmd{
				Name: "bash", Args: []string{script.Path}, Env: envList,
			})
		} else {
			code, err = p.ExecWithOptions(runCtx, container, opts, "bash", script.Path)
		}
		timedOut := runCtx.Err() == context.DeadlineExceeded
		cancel()

		elapsed := int(time.Since(started).Seconds())
		switch {
		case timedOut:
			fmt.Fprintf(out, "  %s ✗ timed out after %ds\n", label, int(timeout.Seconds()))
			return fmt.Errorf("Hook %s timed out on %s after %ds",
				ev.Name, container, int(timeout.Seconds()))
		case err == nil && code == 0:
			fmt.Fprintf(out, "  %s ✓ (%ds)\n", label, elapsed)
		default:
			fmt.Fprintf(out, "  %s ✗ exit %d (%ds)\n", label, code, elapsed)
			return fmt.Errorf("Hook %s failed on %s (exit %d)", ev.Name, container, code)
		}
	}
	return nil
}

// hookEnv is the MPD_HOOK_* environment one firing hands its scripts:
// the standard three plus the event's own values, prefixed.
func hookEnv(ev Event, verb string) map[string]string {
	env := map[string]string{
		"MPD_HOOK_EVENT":    ev.Name,
		"MPD_HOOK_REVISION": fmt.Sprint(ev.Revision),
		"MPD_HOOK_VERB":     verb,
	}
	for k, v := range ev.Env {
		env["MPD_HOOK_"+k] = v
	}
	return env
}

// hookEnvList renders that environment as KEY=VALUE, for the VM audience,
// which runs bash directly rather than through podman.
func hookEnvList(ev Event, verb string) []string {
	env := hookEnv(ev, verb)
	var list []string
	for _, k := range sortedKeys(env) {
		list = append(list, k+"="+env[k])
	}
	return list
}

// execOptions renders the podman exec flags for one firing: the
// environment, plus the identity for a runtime audience.
//
// Sorted so the podman command line is deterministic — otherwise two
// identical fires produce different argv, which makes debugging and
// output comparison needlessly hard.
func execOptions(ev Event, audience AudienceKind, env map[string]string) []string {
	if env == nil {
		env = hookEnv(ev, "")
	}
	var opts []string
	for _, k := range sortedKeys(env) {
		opts = append(opts, "--env", k+"="+env[k])
	}
	// The dev user owns the home a runtime hook works in, and the
	// privilege rule puts asset scripts there. Without this a hook lands
	// in /root and quietly does the wrong thing.
	if audience == AudienceRuntime && ev.User != "" {
		opts = append(opts, "--user", ev.User)
	}
	return opts
}

func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// Script is one discovered hook.
type Script struct {
	Basename string
	// Path is where the script lives. The same string on both sides for a
	// container audience — /opt/mpd/assets is bind-mounted at the same
	// path — and a plain VM path for AudienceVM.
	Path string
}

// discover finds the hook scripts for an event on one audience, in
// layer order.
//
// Which assets apply comes from the CONTAINER's own labels, not from the
// event. mpd-pre-stop fires on every running database at once and those
// may be different engines, so a single engine carried on the event
// would send postgres's hooks into mariadb. The container knows what it
// is; ask it.
//
// Only `*.sh` is considered. Without that filter every file in the
// directory gets handed to bash — an editor backup, a `.bak`, a stray
// `.swp`, a README. See docs/hooks.md.
func discover(ctx context.Context, p *podman.Client, ev Event, audience AudienceKind, container string) []Script {
	var dirs []string

	switch audience {
	case AudienceRuntime:
		// The runtime layer only. There is deliberately NO project-type
		// layer for runtime-audience events: adding one would fire hooks
		// outside the v1 hook contract (docs/hooks.md). The former base
		// layer merged into this one with assets/runtime-base.
		dirs = append(dirs,
			filepath.Join(assetsDir, "runtime", "hooks", ev.Name+".d"))
	case AudienceDatabase:
		// Per-engine only; DB images are stock, so there is no base layer.
		if engine := containerLabel(ctx, p, container, "mpd.db.engine"); engine != "" {
			dirs = append(dirs, filepath.Join(assetsDir, "databases", engine, "hooks", ev.Name+".d"))
		}
	case AudienceService:
		if ev.ServiceName != "" {
			dirs = append(dirs, filepath.Join(assetsDir, "services", ev.ServiceName, "hooks", ev.Name+".d"))
		}
	case AudienceVM:
		// The VM layer, sibling of the runtime one: assets/vm holds what
		// belongs to the VM host (its tools, its shell include), so its
		// hooks live there too.
		dirs = append(dirs,
			filepath.Join(assetsDir, "vm", "hooks", ev.Name+".d"))
	}

	var scripts []Script
	for _, dir := range dirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		var names []string
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".sh") {
				continue
			}
			names = append(names, e.Name())
		}
		sort.Strings(names)
		for _, n := range names {
			scripts = append(scripts, Script{
				Basename: n,
				Path:     filepath.Join(dir, n),
			})
		}
	}
	return scripts
}

// containerLabel reads a label, tolerating a nil client so discovery can
// be exercised in tests without podman.
func containerLabel(ctx context.Context, p *podman.Client, container, key string) string {
	if p == nil || container == "" {
		return ""
	}
	return p.Label(ctx, container, key)
}
