package cli

import (
	"context"
	"fmt"
	"io"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/current"
	"github.com/mutms/mpd/go/internal/db"
	"github.com/mutms/mpd/go/internal/dnsmasq"
	"github.com/mutms/mpd/go/internal/hooks"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/project"
	"github.com/mutms/mpd/go/internal/sidecar"
	"github.com/mutms/mpd/go/internal/srv"
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

// hookProject builds the hook-facing view of a project.
//
// No project-type fields: hook discovery reads the container's labels,
// and runtime-audience events have no type-level layer in v1.
func hookProject(entry state.Project, container string, d ProjectDeps) hooks.Project {
	return hooks.Project{
		Name:             entry.Name,
		Runtime:          entry.RuntimeName,
		RuntimeContainer: container,
		DBEngine:         entry.DatabaseEngine,
		DBVersion:        entry.DatabaseVersion,
	}
}

// ProjectDelete removes a project and everything scoped to it.
//
// Unlike `db delete`, which only recently learned to remove its data,
// this has always been a full removal: source tree, dataroot, meta, the
// project's database inside its engine, and its DNS record. The prompt
// says so before asking.
func ProjectDelete(ctx context.Context, out io.Writer, in io.Reader, name string,
	d ProjectDeps, assumeYes bool) error {

	entry, found := findProject(d.State, name)
	if !found {
		return fmt.Errorf("Project '%s' not found.", name)
	}
	container := d.Observer.RuntimeContainer(entry.RuntimeName)

	typeStr := entry.Type
	if typeStr == "" {
		typeStr = "(not detected)"
	}
	runtimeStr := entry.RuntimeName
	if runtimeStr == "" {
		runtimeStr = "(none)"
	}
	fmt.Fprintf(out, "Project:  %s\n", name)
	fmt.Fprintf(out, "Type:     %s\n", typeStr)
	fmt.Fprintf(out, "Runtime:  %s\n", runtimeStr)
	fmt.Fprintf(out, "Source:   /srv/projects/%s/\n", name)
	fmt.Fprintln(out, "This will remove the DB, dataroot, source tree, and all config files.")

	if !assumeYes && !promptYesNo(out, in, fmt.Sprintf("Remove project '%s'?", name)) {
		fmt.Fprintln(out, "Aborted.")
		return nil
	}

	// Stop first so the type's stop path runs while its runtime is still
	// up — after removal there is nothing left to stop cleanly.
	if entry.Requested == "running" {
		if err := ProjectStop(ctx, out, name, d); err != nil {
			fmt.Fprintf(out, "Warning: stop failed, continuing with delete: %v\n", err)
		}
	}

	// The type's own teardown (Apache alias, systemd unit, …) — only
	// possible while the runtime is running.
	if entry.RuntimeName != "" && d.Podman.Running(ctx, container) {
		if cfg, ok := d.Assets.ProjectTypeConfig(entry.Type); ok {
			script := fmt.Sprintf("/opt/mpd/assets/runtimes/%s/project_types/%s/project-delete.sh",
				cfg.AssetsRuntime, cfg.AssetsType)
			_, _ = project.Exec(ctx, d.Podman, container, d.DevUser, "bash", script, name)
		}
	}

	// The project's database inside its engine — not the engine itself,
	// which other projects share.
	if entry.DatabaseEngine != "" {
		dbContainer := db.ContainerName(entry.DatabaseEngine, entry.DatabaseVersion)
		if d.Podman.Running(ctx, dbContainer) {
			if err := db.Drop(ctx, out, entry.DatabaseEngine, dbContainer, name, d.Podman); err != nil {
				fmt.Fprintf(out, "Warning: %v\n", err)
			}
		}
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

	for _, path := range []string{
		srv.ProjectDir(name),
		filepath.Join(srv.Dir, "data", name),
		srv.MetaDir(name),
	} {
		if err := srv.Remove(ctx, path); err != nil {
			return err
		}
	}

	if err := d.State.DeleteProject(name); err != nil {
		return err
	}

	// Sidecars are derived from the projects present, so removing one can
	// make a sidecar unnecessary — e.g. selenium when this was the last
	// project publishing a behat URL.
	if entry.RuntimeName != "" {
		pod := podName(d.Observer, entry.RuntimeName)
		desired := sidecar.Desired(entry.RuntimeName, d.State, d.Assets)
		if err := sidecar.Reconcile(ctx, out, pod, desired, d.Podman); err != nil {
			fmt.Fprintf(out, "Warning: sidecar reconcile: %v\n", err)
		}
	}

	Ok(out, "Project '%s' deleted.", name)
	return nil
}

// ProjectConfigure applies mpd.env mutations, runs the project type's
// configure.sh, and reconciles everything that depends on its output.
//
// The order is a data dependency chain, not a preference: mutations land
// in mpd.env → configure.sh resolves the four-layer env and emits
// effective.json + urls.json → mpd reads dbTag from effective.json to
// provision the database → URLs drive cert, DNS and sidecars.
func ProjectConfigure(ctx context.Context, out io.Writer, name string, args []string,
	d ProjectDeps) error {

	entry, found := findProject(d.State, name)
	if !found {
		return fmt.Errorf("Project '%s' not found. Create it: mpd %s create", name, name)
	}

	mutations, err := project.ParseMutations(args, func(tag string) error {
		_, _, err := db.ParseTag(tag)
		return err
	})
	if err != nil {
		return err
	}

	// Type is immutable — it decides which asset scripts run, so changing
	// it would mean re-scaffolding, which is what `create` is for.
	if entry.Type == "" {
		return fmt.Errorf("Project type is not set for '%s'.\n"+
			"Create a new project to choose a type (default: moodle).", name)
	}
	if entry.RuntimeName == "" {
		rt, ok := d.Assets.DefaultRuntimeForType(entry.Type)
		if !ok || rt == "" {
			return fmt.Errorf("Cannot determine runtime for '%s' because project type is missing.\n"+
				"Create a new project to choose a type (default: moodle).", name)
		}
		entry.RuntimeName = rt
	}

	container := d.Observer.RuntimeContainer(entry.RuntimeName)
	if !d.Podman.Exists(ctx, container) {
		return fmt.Errorf("Runtime '%s' does not exist — `mpd --runtime-create %s` first "+
			"(runtime create is not ported to the Go binary yet).",
			entry.RuntimeName, entry.RuntimeName)
	}
	runtimeWasRunning := d.Podman.Running(ctx, container)
	if !runtimeWasRunning {
		if err := RuntimeStart(ctx, out, entry.RuntimeName, d.Podman, d.State,
			d.Dnsmasq, d.Observer, d.Net, d.DevUser, d.UID); err != nil {
			return err
		}
	}

	if len(mutations) > 0 {
		fmt.Fprintf(out, "\n\033[1m==> Updating /srv/projects/%s/mpd.env\033[0m\n", name)
		for _, m := range mutations {
			code, err := project.Exec(ctx, d.Podman, container, d.DevUser,
				"bash", "/opt/mpd/assets/runtime-base/tools/set-mpd-env",
				"/srv/projects/"+name+"/mpd.env", m.Key, m.Value)
			if err != nil || code != 0 {
				return fmt.Errorf("Failed to update mpd.env (key '%s').", m.Key)
			}
		}
	}

	// Write project.json first: source-mpd-env.sh reads runtime and type
	// from it to locate the mpd-defaults.env layers configure.sh needs.
	if err := project.WriteMeta(ctx, d.Podman, d.UID, entry); err != nil {
		return err
	}

	cfg, hasType := d.Assets.ProjectTypeConfig(entry.Type)
	if hasType {
		script := fmt.Sprintf("/opt/mpd/assets/runtimes/%s/project_types/%s/scripts/configure.sh",
			cfg.AssetsRuntime, cfg.AssetsType)
		code, err := project.Exec(ctx, d.Podman, container, d.DevUser, "bash", script, name)
		if err != nil || code != 0 {
			return fmt.Errorf("configure.sh failed for project '%s'.", name)
		}
	}

	// dbTag comes from the layered env, so only configure.sh can resolve
	// it — mpd reads the answer rather than duplicating the cascade.
	effective := project.ReadEffective(name)
	dbTag, _ := effective["dbTag"].(string)

	if dbTag != "" {
		ref, err := db.Resolve(ctx, dbTag, d.Podman)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "\n\033[1m==> Ensuring DB container %s\033[0m\n", ref.Container)
		if err := db.Ensure(ctx, ref, d.Podman, d.Net, d.UID, out); err != nil {
			return err
		}
		fmt.Fprintf(out, "\n\033[1m==> Creating database '%s'\033[0m\n", name)
		if err := db.CreateFor(ctx, out, ref.Engine, ref.Container, name, d.Podman); err != nil {
			return err
		}
		entry.DatabaseEngine, entry.DatabaseVersion, entry.DatabaseID = ref.Engine, ref.Version, ref.ID

		if err := db.RebuildStateCache(ctx, d.Podman, d.State); err != nil {
			return err
		}
		changed, err := d.Dnsmasq.EnsureDatabaseRecords(ctx)
		if err != nil {
			return err
		}
		if changed {
			if err := d.Dnsmasq.Restart(ctx); err != nil {
				return err
			}
		}
	} else {
		// Clear stale DB fields: a project that dropped MPD_DB must stop
		// claiming a database it no longer uses.
		entry.DatabaseEngine, entry.DatabaseVersion, entry.DatabaseID = "", "", ""
	}

	entry.URLs = project.ReadURLs(name)
	if entry.Requested == "not-configured" && entry.Type != "" {
		entry.Requested = "stopped"
	}
	if err := project.WriteMeta(ctx, d.Podman, d.UID, entry); err != nil {
		return err
	}
	if err := d.State.UpsertProject(entry); err != nil {
		return err
	}

	pod := podName(d.Observer, entry.RuntimeName)
	if err := sidecar.Reconcile(ctx, out, pod,
		sidecar.Desired(entry.RuntimeName, d.State, d.Assets), d.Podman); err != nil {
		fmt.Fprintf(out, "Warning: sidecar reconcile: %v\n", err)
	}
	if err := project.EnsureCert(ctx, out, name, entry.URLs, d.Net, d.Podman, d.UID); err != nil {
		return err
	}

	// Configure is meant to be low-impact: if it had to start a runtime
	// to do repair work, put it back unless something is actually using it.
	if !runtimeWasRunning {
		inUse := false
		for _, p := range d.State.Projects() {
			if p.RuntimeName == entry.RuntimeName && p.Requested == "running" {
				inUse = true
				break
			}
		}
		if !inUse {
			_ = RuntimeStop(ctx, out, entry.RuntimeName, d.Podman, d.State, d.Dnsmasq, d.Observer)
		}
	}

	Ok(out, "Project '%s' configured. Type: %s, Status: %s", name, entry.Type, entry.Requested)
	return nil
}

// projectVerbs are names a project may not take, because `mpd <name>
// <verb>` would become ambiguous.
var projectVerbs = map[string]bool{
	"show": true, "help": true, "create": true, "configure": true,
	"start": true, "stop": true, "delete": true, "project": true,
}

var validProjectName = regexp.MustCompile(`^[a-z][a-z0-9]*(-[a-z0-9]+)*$`)

// CreateOptions carries `project create`'s flags.
type CreateOptions struct {
	Type      string
	GitRepo   string
	GitBranch string
	GitDepth  string
}

// ProjectCreate scaffolds a new project.
//
// Deliberately does NOT configure it: create lays down the source tree
// and an mpd.env seeded from the type's template, then stops so the
// developer can edit that file before anything acts on it. `configure`
// is the step that resolves the env and provisions a database.
func ProjectCreate(ctx context.Context, out io.Writer, name string, opts CreateOptions,
	d ProjectDeps, home string) error {

	if !validProjectName.MatchString(name) || len(name) < 2 {
		return fmt.Errorf("'%s' is not a valid project name. "+
			"Use lowercase letters and digits, starting with a letter, "+
			"minimum 2 characters. Internal dashes allowed "+
			"(e.g. 'moodle520-cftunnel').", name)
	}
	if projectVerbs[name] {
		return fmt.Errorf("Project name '%s' is reserved by CLI syntax. Choose another name.", name)
	}
	if _, exists := findProject(d.State, name); exists {
		return fmt.Errorf("Project '%s' already exists.", name)
	}

	// Explicit --type wins; otherwise infer from the name, falling back
	// to moodle as mpd's overall default.
	typeName := opts.Type
	if typeName == "" {
		typeName = d.Assets.DetectTypeFromName(name)
	}
	if typeName == "" {
		typeName = "moodle"
	}

	runtimeName, ok := d.Assets.DefaultRuntimeForType(typeName)
	if !ok || runtimeName == "" {
		runtimeName = "php"
	}

	// Resolve and start the runtime BEFORE touching any project state, so
	// a failure here leaves nothing half-created.
	if err := ensureRuntime(ctx, out, runtimeName, d, home); err != nil {
		return err
	}
	container := d.Observer.RuntimeContainer(runtimeName)

	fmt.Fprintf(out, "\n\033[1m==> Ensuring /srv/projects/%s/\033[0m\n", name)
	if code, err := project.Exec(ctx, d.Podman, container, d.DevUser,
		"mkdir", "-p", "/srv/projects/"+name); err != nil || code != 0 {
		return fmt.Errorf("Failed to create /srv/projects/%s in runtime '%s'.", name, runtimeName)
	}

	if opts.GitRepo != "" {
		// A runtime created moments ago has just had dnsmasq restarted
		// under it, so the clone can race the resolver coming back. Wait
		// for the git host to resolve from inside the container rather
		// than letting the user meet a confusing clone failure.
		if host := gitHost(opts.GitRepo); host != "" {
			waitForHostResolves(ctx, out, d.Podman, container, d.DevUser, host)
		}
		fmt.Fprintf(out, "\n\033[1m==> Cloning %s\033[0m\n", opts.GitRepo)
		// --progress because git's isatty check can fail through podman
		// exec, leaving a large clone apparently frozen.
		args := []string{"git", "clone", "--progress"}
		if opts.GitBranch != "" {
			args = append(args, "-b", opts.GitBranch)
		}
		if opts.GitDepth != "" {
			args = append(args, "--depth="+opts.GitDepth)
		}
		args = append(args, opts.GitRepo, "/srv/projects/"+name)
		if code, err := project.Exec(ctx, d.Podman, container, d.DevUser, args...); err != nil || code != 0 {
			return fmt.Errorf("git clone failed.")
		}
	}

	// The type's own scaffolding: seeds mpd.env from its template and
	// excludes it from git. Optional — types without the script skip.
	if cfg, ok := d.Assets.ProjectTypeConfig(typeName); ok {
		script := fmt.Sprintf("/opt/mpd/assets/runtimes/%s/project_types/%s/project-create.sh",
			cfg.AssetsRuntime, cfg.AssetsType)
		if d.Assets.HasFile(fmt.Sprintf("runtimes/%s/project_types/%s/project-create.sh",
			cfg.AssetsRuntime, cfg.AssetsType)) {
			fmt.Fprintf(out, "\n\033[1m==> Scaffolding project from %s template\033[0m\n", typeName)
			if code, err := project.Exec(ctx, d.Podman, container, d.DevUser,
				"bash", script, name); err != nil || code != 0 {
				return fmt.Errorf("project-create.sh failed for project '%s'.", name)
			}
		}
	}

	// Registered only after scaffolding succeeds. If anything above
	// failed, no entry is written and /srv/projects/<name>/ is left for
	// the developer to inspect, fix, or remove.
	if err := d.State.UpsertProject(state.Project{
		Name: name, Type: typeName, Requested: "not-configured",
	}); err != nil {
		return err
	}

	fmt.Fprintln(out, "")
	Ok(out, "Project '%s' scaffolded.", name)
	fmt.Fprintf(out, "  Edit /srv/projects/%s/mpd.env if needed, then:\n", name)
	fmt.Fprintf(out, "    mpd configure %s\n", name)
	return nil
}

// ensureRuntime creates the runtime if absent, starts it if stopped.
func ensureRuntime(ctx context.Context, out io.Writer, name string, d ProjectDeps, home string) error {
	container := d.Observer.RuntimeContainer(name)
	switch {
	case !d.Podman.Exists(ctx, container):
		fmt.Fprintf(out, "No runtime '%s' — creating...\n", name)
		return RuntimeCreate(ctx, out, name, d.Podman, d.State, d.Dnsmasq, d.Observer,
			d.Net, d.Assets, d.DevUser, d.UID, home)
	case !d.Podman.Running(ctx, container):
		return RuntimeStart(ctx, out, name, d.Podman, d.State, d.Dnsmasq, d.Observer,
			d.Net, d.DevUser, d.UID)
	}
	return nil
}

// gitHost extracts the host from a git URL, handling both URL form and
// the scp-like user@host:path form git accepts.
func gitHost(raw string) string {
	if u, err := url.Parse(raw); err == nil && u.Host != "" {
		return u.Hostname()
	}
	if at := strings.Index(raw, "@"); at >= 0 {
		rest := raw[at+1:]
		if colon := strings.Index(rest, ":"); colon > 0 {
			host := rest[:colon]
			if !strings.Contains(host, "/") {
				return host
			}
		}
	}
	return ""
}

// waitForHostResolves polls until a hostname resolves inside the
// container, up to ~15s. Non-fatal: the clone reports its own error if
// DNS never comes back.
func waitForHostResolves(ctx context.Context, out io.Writer, p *podman.Client,
	container, user, host string) {

	for i := 0; i < 30; i++ {
		if code := p.ExecQuietly(ctx, container, "getent", "hosts", host); code == 0 {
			return
		}
		if i == 0 {
			fmt.Fprintf(out, "  Waiting for '%s' to resolve inside the runtime…\n", host)
		}
		time.Sleep(500 * time.Millisecond)
	}
}

// ShowHelp prints the per-project verb reference.
//
// Ends by pointing at the runtime rather than listing more verbs, because
// the project-type operations developers reach for next — mdl-cron,
// phpunit, composer — are tools on PATH inside the runtime, not host-side
// verbs. See AGENTS.md §"Authoring verbs and tools".
func ShowHelp(out io.Writer, project string, n net.Net) {
	fmt.Fprintf(out, "Usage: mpd <verb> %s [options...]\n", project)
	fmt.Fprintln(out, "\nVerbs:")
	fmt.Fprintf(out, "  show       %s                       project details (also: bare `mpd show %s`)\n", project, project)
	fmt.Fprintf(out, "  create     %s [--type=<type>] [--git-repo=<url>] [--git-branch=<branch>] [--git-depth=<n>]\n", project)
	fmt.Fprintln(out, "                                              (default type: moodle)")
	fmt.Fprintf(out, "  configure  %s [KEY=VALUE ...]       (e.g. MPD_DB=postgres:18, MPD_PHP_VERSION=8.4;\n", project)
	fmt.Fprintf(out, "                                              full set lives in /srv/projects/%s/mpd.env)\n", project)
	fmt.Fprintf(out, "  start      %s\n", project)
	fmt.Fprintf(out, "  stop       %s\n", project)
	fmt.Fprintf(out, "  delete     %s [--yes]\n", project)
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "Project-type-specific operations (mdl-cron, phpunit, composer, …) are tools,")
	fmt.Fprintln(out, "not host-side verbs. SSH into the runtime and run them on PATH:")
	fmt.Fprintf(out, "  ssh user@<runtime>.runtime.%s\n", n.Zone())
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "Or forward one from the VM, from inside the project directory:")
	fmt.Fprintf(out, "  cd /srv/projects/%s && mpd run <command> [args...]\n", project)
}
