package cli

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/current"
	"github.com/mutms/mpd/go/internal/db"
	"github.com/mutms/mpd/go/internal/dnsmasq"
	"github.com/mutms/mpd/go/internal/hooks"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/project"
	"github.com/mutms/mpd/go/internal/state"
)

// ProjectDeps bundles what the project verbs need. Passed as a struct
// because the alternative is an eight-argument signature repeated per
// verb.
type ProjectDeps struct {
	Podman   *podman.Client
	State    state.Store
	Dnsmasq  dnsmasq.Manager
	Observer current.Observer
	Assets   assets.Tree
	Net      net.Net
	DevUser  string
	UID      string
}

// ProjectStart brings a project up.
//
// Order matters throughout: the runtime and database must be up before
// pre-start hooks fire (they exist to prepare the database), the cert
// and DNS record must exist before the type's setup script runs (which
// may probe its own URL), and `requested` is only recorded after setup
// succeeds — so a failed start does not leave a project claiming to run.
func ProjectStart(ctx context.Context, out io.Writer, name string, d ProjectDeps) error {
	entry, found := findProject(d.State, name)
	if !found {
		return fmt.Errorf("Project '%s' not found. Create it: mpd %s create", name, name)
	}
	if entry.RuntimeName == "" {
		return fmt.Errorf("No runtime assigned to '%s'.\nUse: mpd %s create", name, name)
	}

	container := d.Observer.RuntimeContainer(entry.RuntimeName)
	if !d.Podman.Exists(ctx, container) {
		return fmt.Errorf("Runtime '%s' does not exist.", entry.RuntimeName)
	}
	if !d.Podman.Running(ctx, container) {
		if err := RuntimeStart(ctx, out, entry.RuntimeName, d.Podman, d.State,
			d.Dnsmasq, d.Observer, d.Net, d.DevUser, d.UID); err != nil {
			return err
		}
	}

	if entry.DatabaseEngine != "" {
		ref, err := db.Resolve(ctx, entry.DatabaseEngine+":"+entry.DatabaseVersion, d.Podman)
		if err != nil {
			return err
		}
		if err := db.Ensure(ctx, ref, d.Podman, d.Net, d.UID, out); err != nil {
			return err
		}
	}

	ev := hookProject(entry, container, d)

	// Pre-start: runtime and DB are up, project setup has not run. Hook
	// authors apply migrations or seed data here. Failure aborts —
	// a project whose precondition failed should not come up.
	if err := hooks.Fire(ctx, out, hooks.ProjectPreStart(ctx, ev, d.Podman), "start", d.Podman); err != nil {
		return err
	}

	if err := project.EnsureCert(ctx, out, name, entry.URLs, d.Net, d.Podman, d.UID); err != nil {
		return err
	}

	runtimeIP := d.Podman.Label(ctx, container, "mpd.ip")
	if body, ok := project.DNSRecords(name, entry.URLs, runtimeIP, d.Net); ok {
		changed, err := d.Dnsmasq.WriteRecord(name, body)
		if err != nil {
			return err
		}
		if changed {
			if err := d.Dnsmasq.Restart(ctx); err != nil {
				return err
			}
		}
	}

	if cfg, ok := d.Assets.ProjectTypeConfig(entry.Type); ok {
		fmt.Fprintf(out, "\n\033[1m==> Setting up '%s' in '%s'\033[0m\n", name, entry.RuntimeName)
		script := fmt.Sprintf("/opt/mpd/assets/runtimes/%s/project_types/%s/project-setup.sh",
			cfg.AssetsRuntime, cfg.AssetsType)
		code, err := project.Exec(ctx, d.Podman, container, d.DevUser, "bash", script, name)
		if err != nil || code != 0 {
			return fmt.Errorf("project-setup.sh failed.")
		}
	}

	entry.Requested = "running"
	if err := d.State.UpsertProject(entry); err != nil {
		return err
	}

	// Post-start: fully live. Failures warn but never undo the start.
	if err := hooks.Fire(ctx, out, hooks.ProjectPostStart(ctx, ev, d.Podman), "start", d.Podman); err != nil {
		fmt.Fprintf(out, "Warning: %v\n", err)
	}

	Ok(out, "'%s' is running.", name)
	if url := entry.MainURL(); url != "" {
		fmt.Fprintf(out, "  %s\n", url)
	}
	return nil
}

// ProjectStop takes a project down.
//
// Note what it does NOT do: stop the runtime, or stop the database. mpd
// is demand-driven (docs/HOOKS.md §"Resource lifecycle model") — devs
// poke at a database after the project is down, and cascading stops
// would fight that. Reclaiming idle resources is `mpd --gc`'s job.
func ProjectStop(ctx context.Context, out io.Writer, name string, d ProjectDeps) error {
	entry, found := findProject(d.State, name)
	if !found {
		return fmt.Errorf("Project '%s' not found. Create it: mpd %s create", name, name)
	}
	if entry.Requested != "running" {
		fmt.Fprintf(out, "'%s' is already stopped.\n", name)
		return nil
	}

	container := d.Observer.RuntimeContainer(entry.RuntimeName)
	ev := hookProject(entry, container, d)

	// Pre-stop: still live, so hooks can drain work or flush caches.
	// Failure is logged, never blocking — you cannot fail to stop.
	if err := hooks.Fire(ctx, out, hooks.ProjectPreStop(ctx, ev, d.Podman), "stop", d.Podman); err != nil {
		fmt.Fprintf(out, "Warning: %v\n", err)
	}

	// Types running their own dev server need it stopped explicitly;
	// types served through the frontdoor have nothing to stop.
	if cfg, ok := d.Assets.ProjectTypeConfig(entry.Type); ok && cfg.StopSystemd {
		if d.Podman.Running(ctx, container) {
			_, _ = project.Exec(ctx, d.Podman, container, d.DevUser,
				"sudo", "systemctl", "stop", "mpd-"+name)
		}
	}

	entry.Requested = "stopped"
	if err := d.State.UpsertProject(entry); err != nil {
		return err
	}

	removed, err := d.Dnsmasq.RemoveRecord(name)
	if err != nil {
		return err
	}
	if removed {
		if err := d.Dnsmasq.Restart(ctx); err != nil {
			return err
		}
	}

	Ok(out, "'%s' stopped.", name)
	return nil
}

func findProject(s state.Store, name string) (state.Project, bool) {
	for _, p := range s.Projects() {
		if p.Name == name {
			return p, true
		}
	}
	return state.Project{}, false
}

// hookProject builds the hook-facing view of a project, resolving the
// type's asset location so type-level hooks are discoverable.
func hookProject(entry state.Project, container string, d ProjectDeps) hooks.Project {
	pr := hooks.Project{
		Name:             entry.Name,
		Runtime:          entry.RuntimeName,
		RuntimeContainer: container,
		DBEngine:         entry.DatabaseEngine,
		DBVersion:        entry.DatabaseVersion,
	}
	if cfg, ok := d.Assets.ProjectTypeConfig(entry.Type); ok {
		pr.Type = cfg.AssetsType
		pr.TypeRuntime = cfg.AssetsRuntime
	}
	return pr
}
