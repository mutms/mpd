// Package hooks dispatches mpd's typed lifecycle events to bash scripts
// in the asset tree.
//
// Events, hooks and audiences are defined in docs/hooks.md. The event
// names, the MPD_HOOK_* environment and the ordering are a public
// contract for scripts outside this repo and must not drift.
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
// inside every container — so a host-side scan yields a path the
// container can execute.
const AssetsDir = "/opt/mpd/assets"

// assetsDir is what discovery reads; tests point it at a fixture tree.
var assetsDir = AssetsDir

// DefaultTimeout bounds a hook script that declares none.
//
// Caveat, verified: killing `podman exec` does NOT kill the process
// inside the container. A timed-out hook stops blocking mpd, but its
// script keeps running until it finishes or the container stops.
const DefaultTimeout = 30 * time.Second

// StopTimeout bounds mpd-pre-stop, where a database flushing pending IO
// legitimately takes longer than a normal hook.
const StopTimeout = 120 * time.Second

// SetupTimeout bounds mpd-post-setup, whose hooks install things.
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
	// AudienceVM: the VM host itself, for work no container can do.
	AudienceVM
)

// VMTarget labels AudienceVM output where others print a container name.
const VMTarget = "vm"

// FailureMode decides what a failing hook does to the firing verb.
type FailureMode int

const (
	// Abort: hook failure fails the verb. For preconditions.
	Abort FailureMode = iota
	// Continue: hook failure is logged and the verb proceeds. For
	// cleanup and post-state events: you cannot fail to stop.
	Continue
)

// Event is one typed lifecycle moment.
type Event struct {
	// Name is the kebab-case event name, matching the `<name>.d` directory.
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
	// User is who runtime hooks run as; empty means root. AudienceRuntime
	// only — DB and service containers have no dev user.
	User string
}

// Fire runs every hook for an event, honouring its failure mode.
//
// Ordering is part of the contract: audiences in declared order,
// containers within an audience, then scripts alphabetically — which is
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

// targets resolves an audience. AudienceVM is always the one VM.
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

		// The timeout is enforced: a hook that never returns would hang
		// the verb, and for mpd-pre-stop, hang VM shutdown.
		runCtx, cancel := context.WithTimeout(ctx, timeout)
		var code int
		var err error
		if audience == AudienceVM {
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

// hookEnv is the MPD_HOOK_* environment: the standard three plus the
// event's own values, prefixed.
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

// hookEnvList renders that as KEY=VALUE, for the VM audience.
func hookEnvList(ev Event, verb string) []string {
	env := hookEnv(ev, verb)
	var list []string
	for _, k := range sortedKeys(env) {
		list = append(list, k+"="+env[k])
	}
	return list
}

// execOptions renders the podman exec flags. Sorted, so argv is
// deterministic.
func execOptions(ev Event, audience AudienceKind, env map[string]string) []string {
	if env == nil {
		env = hookEnv(ev, "")
	}
	var opts []string
	for _, k := range sortedKeys(env) {
		opts = append(opts, "--env", k+"="+env[k])
	}
	// Without --user a runtime hook lands in /root, not the dev's home.
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
	// Path is the same string inside a container and on the VM, since
	// /opt/mpd is mounted at the same path.
	Path string
}

// discover finds the hook scripts for an event on one audience.
//
// Which assets apply comes from the CONTAINER's labels, not the event:
// mpd-pre-stop fires on every running database at once, and a single
// engine on the event would send one engine's hooks into another. Only
// `*.sh` is considered, so editor backups and READMEs are never handed
// to bash (see docs/hooks.md).
func discover(ctx context.Context, p *podman.Client, ev Event, audience AudienceKind, container string) []Script {
	var dirs []string

	switch audience {
	case AudienceRuntime:
		// Deliberately no project-type layer here: firing one would
		// break the v1 hook contract (docs/hooks.md).
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

// containerLabel reads a label, tolerating a nil client so discovery
// can be tested without podman.
func containerLabel(ctx context.Context, p *podman.Client, container, key string) string {
	if p == nil || container == "" {
		return ""
	}
	return p.Label(ctx, container, key)
}
