package cli

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
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
	"github.com/mutms/mpd/go/internal/runtime"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/vm"
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
		// The project exists but has never been configured — the state
		// `create` leaves, and the state `reset` returns it to. Configure is
		// what assigns the runtime and builds the database, so pointing at
		// `create` here would send the caller to a verb that refuses because
		// the project already exists.
		return fmt.Errorf("Project '%s' is not configured yet, so it has no runtime or database.\n"+
			"Run: mpd configure %s", name, name)
	}

	container := d.Observer.RuntimeContainer(entry.RuntimeName)
	if !d.Podman.Exists(ctx, container) {
		return fmt.Errorf("The runtime does not exist. Run: mpd --vm-setup")
	}
	if !d.Podman.Running(ctx, container) {
		if err := RuntimeStart(ctx, out, d.Podman, d.State,
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
		// db.Ensure may have just created the container, and its address
		// is only known once it exists. Without this the project comes up
		// with a database it cannot name: Moodle reports
		// "dbconnectionfailed" on a DB that is running and healthy.
		if _, err := d.Dnsmasq.EnsureDatabaseRecords(ctx); err != nil {
			return err
		}
	}

	// urls.json is the source of truth; projects.json holds a copy that
	// only `configure` refreshes. Re-read it before anything downstream
	// uses it — the cert SANs and the DNS record below are both composed
	// from entry.URLs, so a stale copy silently re-establishes a project
	// under names it no longer has.
	//
	// Checked BEFORE it is adopted: configuration judged unusable must not
	// be written into state, or a failed start leaves projects.json
	// advertising another VM's URLs.
	urls := entry.URLs
	if fresh, ok := project.ReadURLs(name); ok {
		urls = fresh
	}
	if err := project.CheckConfigured(name, urls, d.Net); err != nil {
		return err
	}
	if !sameURLs(urls, entry.URLs) {
		entry.URLs = urls
		if err := d.State.UpsertProject(entry); err != nil {
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
		if _, err := d.Dnsmasq.WriteRecord(name, body); err != nil {
			return err
		}
	}

	cfg, hasType := d.Assets.ProjectTypeConfig(entry.Type)
	if hasType {
		fmt.Fprintf(out, "\n\033[1m==> Setting up '%s' in the runtime\033[0m\n", name)
		script := assets.TypeScript(cfg.AssetsType, "project-setup.sh")
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

	url := entry.MainURL()
	if !hasType || cfg.WaitForURL {
		waitForURL(ctx, out, url)
	}

	Ok(out, "'%s' is running.", name)
	if url != "" {
		fmt.Fprintf(out, "  %s\n", url)
	}
	return nil
}

// waitForURL blocks until the project's main URL answers, up to ~30s.
//
// This is the only readiness gate on what the developer actually opens.
// ProjectStart already waits for sshd and for the database, but the
// frontdoor is updated out of band: mpd writes /srv/meta/<project>/, and
// the in-runtime caddy notices by inotify, coalesces, regenerates, validates
// and reloads on its own schedule (assets/runtime/caddy/mpd-caddy.sh), while
// PHP-FPM binds its new pool independently. Without this, mpd prints
// "is running" while the URL still returns a connection error or a 502.
//
// Deliberately last, and deliberately non-fatal. Every piece of work mpd
// owns — setup script, state write, DNS record, certificate, hooks — has
// already completed and been persisted by the time this runs; what it
// waits on belongs to other processes that do not care whether mpd is
// alive. mpd installs no signal handler, so Ctrl-C here kills the process
// outright — and that is safe precisely because nothing is left to do.
// The timeout path warns for the same reason: a slow frontdoor is worth
// reporting, but it has not failed the start.
func waitForURL(ctx context.Context, out io.Writer, url string) {
	if url == "" {
		return
	}
	client, err := trustingClient()
	if err != nil {
		fmt.Fprintf(out, "  Warning: cannot verify %s: %v\n", url, err)
		return
	}

	// Anything below 500 means the vhost is wired to a live backend. A
	// redirect counts and is not followed: Moodle bounces to a login or
	// setup page, and chasing it proves nothing extra about readiness.
	probe := func() bool {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return false
		}
		resp, err := client.Do(req)
		if err != nil {
			return false
		}
		defer resp.Body.Close()
		return resp.StatusCode < 500
	}

	if probe() {
		return
	}
	fmt.Fprintf(out, "  Waiting for %s to answer…\n", url)
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(500 * time.Millisecond)
		if probe() {
			return
		}
	}
	fmt.Fprintf(out, "  Warning: %s did not answer within 30s.\n", url)
}

// trustingClient is an HTTP client that trusts this VM's anchor and
// nothing else.
//
// Verification is not skipped, because a leaf the local trust store
// rejects is exactly the failure this probe should surface rather than
// paper over: after a CA rotation Caddy can keep serving a certificate
// signed by an anchor nothing trusts any more, with both the config and
// the files on disk looking correct (see assets/runtime/caddy/mpd-caddy.sh).
// An InsecureSkipVerify probe would report that broken project as ready.
func trustingClient() (*http.Client, error) {
	pem, err := os.ReadFile(vm.CACertPath)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, fmt.Errorf("no certificate found in %s", vm.CACertPath)
	}
	return &http.Client{
		Timeout: 3 * time.Second,
		// Redirects are responses, not failures: return the first one.
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12},
		},
	}, nil
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

	// A type may ship project-stop.sh to do — or just to say — whatever
	// stopping means for it. Astro's only prints how to stop the dev
	// server, because that server is the developer's, not mpd's.
	//
	// Optional, and best-effort by design: you cannot fail to stop, so a
	// missing script, a stopped runtime, or a script that errors all
	// leave the project stopped regardless.
	if cfg, ok := d.Assets.ProjectTypeConfig(entry.Type); ok &&
		d.Assets.HasTypeFile(cfg.AssetsType, "project-stop.sh") {
		if d.Podman.Running(ctx, container) {
			script := assets.TypeScript(cfg.AssetsType, "project-stop.sh")
			_, _ = project.Exec(ctx, d.Podman, container, d.DevUser, "bash", script, name)
		}
	}

	entry.Requested = "stopped"
	if err := d.State.UpsertProject(entry); err != nil {
		return err
	}

	// The DNS record stays. It belongs to the project being configured,
	// not to it being up: the name keeps resolving and the URL keeps
	// working the moment something serves again. Only delete (and a
	// runtime that is removed outright) withdraws it.
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
	fmt.Fprintf(out, "To keep the code and start over instead, use `mpd reset %s`.\n", name)

	if !assumeYes && !promptName(out, in, name, "deletion") {
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
			script := assets.TypeScript(cfg.AssetsType, "project-delete.sh")
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

	if _, err := d.Dnsmasq.RemoveRecord(name); err != nil {
		return err
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

	Ok(out, "Project '%s' deleted.", name)
	return nil
}

// ProjectReset throws away a project's data and returns it to the state
// `create` left it in, keeping the source tree.
//
// # What it is for
//
// Two situations, both of which used to mean delete-and-start-over:
//
//   - The database is corrupted, or the site's data is simply not worth
//     keeping, and you want a fresh install against the code you already
//     have. The source tree and config.php survive, so nothing has to be
//     re-cloned and no hand-edited settings are lost.
//   - You want a different database engine. Reset, edit MPD_DB in
//     mpd.env, then configure: config-mpd.php is regenerated from the new
//     value, so the switch needs no manual edit of any PHP file.
//
// # What survives, and why that is the whole point
//
// /srv/projects/<name>/ is untouched — code, git history, mpd.env,
// config.php. configure.sh writes config.php only when it is missing and
// regenerates config-mpd.php every time, which is what lets the DB change
// underneath an unchanged config.php.
//
// Everything derived goes: the project's database, the contents of
// /srv/data/<name>/ (dataroot and its behat/phpunit siblings), the
// generated metadata in /srv/meta/<name>/ including the TLS certificate,
// and the project's DNS record.
//
// # Not configured afterwards, deliberately
//
// The resulting state is exactly what `create` writes — type and name, and
// nothing else — so `start` refuses until `configure` has run. That is the
// honest description of the project at that moment: it has no database, no
// dataroot and no runtime assignment, and pretending otherwise would only
// move the failure to somewhere less obvious. It is also what makes the
// switch-the-database flow work, since configure is what reads the new
// MPD_DB.
//
// The database *engine* container is left running. It is shared with every
// other project on that engine:version, so stopping it would reach outside
// this project, and an idle engine costs nothing.
func ProjectReset(ctx context.Context, out io.Writer, in io.Reader, name string,
	d ProjectDeps, assumeYes bool) error {

	entry, found := findProject(d.State, name)
	if !found {
		return fmt.Errorf("Project '%s' not found.", name)
	}
	container := d.Observer.RuntimeContainer(entry.RuntimeName)

	dbStr := entry.DatabaseID
	if dbStr == "" {
		dbStr = "(none)"
	}
	fmt.Fprintf(out, "Project:  %s\n", name)
	fmt.Fprintf(out, "Type:     %s\n", orDash(entry.Type))
	fmt.Fprintf(out, "Database: %s\n", dbStr)
	fmt.Fprintf(out, "Keeps:    /srv/projects/%s/ (code, mpd.env, config.php)\n", name)
	fmt.Fprintf(out, "Destroys: the '%s' database and everything in /srv/data/%s/\n", name, name)
	fmt.Fprintf(out, "Leaves '%s' not configured — run `mpd configure %s` next.\n", name, name)

	if !assumeYes && !promptName(out, in, name, "reset") {
		fmt.Fprintln(out, "Aborted.")
		return nil
	}

	// Stop while the runtime is still up, so the type's stop path and the
	// pre-stop hooks run against a live project — the same ordering
	// argument as delete.
	if entry.Requested == "running" {
		if err := ProjectStop(ctx, out, name, d); err != nil {
			fmt.Fprintf(out, "Warning: stop failed, continuing with reset: %v\n", err)
		}
	}

	// The type's teardown: Apache alias, systemd unit, whatever it owns.
	// Reset is a re-scaffold, so the project must be torn down as
	// completely as a delete would tear it down — configure.sh builds it
	// all back.
	if entry.RuntimeName != "" && d.Podman.Running(ctx, container) {
		if cfg, ok := d.Assets.ProjectTypeConfig(entry.Type); ok {
			script := assets.TypeScript(cfg.AssetsType, "project-delete.sh")
			_, _ = project.Exec(ctx, d.Podman, container, d.DevUser, "bash", script, name)
		}
	}

	// The project's database inside its engine — never the engine itself.
	if entry.DatabaseEngine != "" {
		dbContainer := db.ContainerName(entry.DatabaseEngine, entry.DatabaseVersion)
		if d.Podman.Running(ctx, dbContainer) {
			fmt.Fprintf(out, "\n\033[1m==> Dropping database '%s'\033[0m\n", name)
			if err := db.Drop(ctx, out, entry.DatabaseEngine, dbContainer, name, d.Podman); err != nil {
				fmt.Fprintf(out, "Warning: %v\n", err)
			}
		} else {
			fmt.Fprintf(out, "Engine %s is not running — skipping the database drop.\n", dbContainer)
		}
	}

	// The record points at a runtime address this project no longer has.
	if _, err := d.Dnsmasq.RemoveRecord(name); err != nil {
		return err
	}

	fmt.Fprintf(out, "\n\033[1m==> Clearing /srv/data/%s/\033[0m\n", name)
	if err := srv.RemoveContents(ctx, srv.DataDir(name)); err != nil {
		return err
	}
	// Generated metadata, including the certificate: all of it is rebuilt
	// by configure from mpd.env, and a certificate for URLs the project no
	// longer publishes should not outlive them.
	if err := srv.Remove(ctx, srv.MetaDir(name)); err != nil {
		return err
	}

	// Exactly what ProjectCreate writes. Assembled field by field rather
	// than by clearing the old entry, so a field added to state.Project
	// later cannot silently survive a reset.
	if err := d.State.UpsertProject(state.Project{
		Name:      entry.Name,
		Type:      entry.Type,
		Requested: "not-configured",
	}); err != nil {
		return err
	}

	fmt.Fprintln(out, "")
	Ok(out, "Project '%s' reset — code kept, data gone, not configured.", name)
	fmt.Fprintf(out, "  Edit /srv/projects/%s/mpd.env (e.g. MPD_DB) if needed, then:\n", name)
	fmt.Fprintf(out, "    mpd configure %s\n", name)
	return nil
}

// ProjectConfigure applies mpd.env mutations, runs the project type's
// configure.sh, and reconciles everything that depends on its output.
//
// The order is a data dependency chain, not a preference: mutations land
// in mpd.env → configure.sh resolves the four-layer env and emits
// effective.json + urls.json → mpd reads dbTag from effective.json to
// provision the database → URLs drive cert and DNS.
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
	// RuntimeName is a JSON contract with shell/jq consumers; there is one
	// runtime, so it is pinned rather than resolved.
	entry.RuntimeName = runtime.Name

	container := d.Observer.RuntimeContainer(entry.RuntimeName)
	if !d.Podman.Exists(ctx, container) {
		return fmt.Errorf("The runtime does not exist. Run: mpd --vm-setup")
	}
	runtimeWasRunning := d.Podman.Running(ctx, container)
	if !runtimeWasRunning {
		if err := RuntimeStart(ctx, out, d.Podman, d.State,
			d.Dnsmasq, d.Observer, d.Net, d.DevUser, d.UID); err != nil {
			return err
		}
	}

	if len(mutations) > 0 {
		fmt.Fprintf(out, "\n\033[1m==> Updating /srv/projects/%s/mpd.env\033[0m\n", name)
		for _, m := range mutations {
			code, err := project.Exec(ctx, d.Podman, container, d.DevUser,
				"bash", "/opt/mpd/assets/runtime/tools/set-mpd-env",
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
		script := assets.TypeScript(cfg.AssetsType, "scripts/configure.sh")
		code, err := project.Exec(ctx, d.Podman, container, d.DevUser, "bash", script, name)
		if err != nil || code != 0 {
			return fmt.Errorf("configure.sh failed for project '%s'.", name)
		}
	}

	// dbTag comes from the layered env, so only configure.sh can resolve
	// it — mpd reads the answer rather than duplicating the cascade.
	effective := project.ReadEffective(name)
	dbTag, _ := effective["dbTag"].(string)

	warnPortClash(out, name, effective, d.State)

	// Behat needs the seleniumv1 service. Turning behat on IS the
	// explicit request, so the service is enabled on its behalf rather
	// than failing the first `behat` run with a connection error. The
	// image is ~2 GB on first enable; the pull streams its progress.
	if behatEnabled(effective) && !serviceEnabled(d.State, "seleniumv1") {
		fmt.Fprintln(out, "\n\033[1m==> Auto-enabling seleniumv1 (behat requested)\033[0m")
		if err := ServiceEnable(ctx, out, "seleniumv1", d.Podman, d.State,
			d.Dnsmasq, d.Net, vm.PrimaryIP()); err != nil {
			return err
		}
	}

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
		if _, err := d.Dnsmasq.EnsureDatabaseRecords(ctx); err != nil {
			return err
		}
	} else {
		// Clear stale DB fields: a project that dropped MPD_DB must stop
		// claiming a database it no longer uses.
		entry.DatabaseEngine, entry.DatabaseVersion, entry.DatabaseID = "", "", ""
	}

	entry.URLs, _ = project.ReadURLs(name)
	if entry.Requested == "not-configured" && entry.Type != "" {
		entry.Requested = "stopped"
	}
	if err := project.WriteMeta(ctx, d.Podman, d.UID, entry); err != nil {
		return err
	}
	if err := d.State.UpsertProject(entry); err != nil {
		return err
	}

	if err := project.EnsureCert(ctx, out, name, entry.URLs, d.Net, d.Podman, d.UID); err != nil {
		return err
	}

	// DNS is published here, not at start: a configured project is an
	// addressable one. The name resolving while nothing serves it yields
	// a dead page, which is the honest answer — and the only one that
	// works for types whose server the developer starts by hand (astro),
	// where mpd never learns that the dev server came up. The record is
	// read off the container label rather than a live inspect, so it is
	// available even when configure left the runtime stopped.
	runtimeIP := d.Podman.Label(ctx, container, "mpd.ip")
	if body, ok := project.DNSRecords(name, entry.URLs, runtimeIP, d.Net); ok {
		if _, err := d.Dnsmasq.WriteRecord(name, body); err != nil {
			return err
		}
	}

	// Configure is meant to be low-impact: if it had to start the runtime
	// to do repair work, put it back unless something is actually using it.
	if !runtimeWasRunning {
		inUse := false
		for _, p := range d.State.Projects() {
			if p.Requested == "running" {
				inUse = true
				break
			}
		}
		if !inUse {
			_ = RuntimeStop(ctx, out, d.Podman, d.State, d.Dnsmasq, d.Observer)
		}
	}

	Ok(out, "Project '%s' configured. Type: %s, Status: %s", name, entry.Type, entry.Requested)
	return nil
}

// warnPortClash reports when another project already claims the loopback
// port this one publishes as its frontdoor upstream.
//
// Worth a warning rather than silence because the failure is invisible:
// caddy points two vhosts at the same 127.0.0.1:<port>, so whichever
// server is up answers for both names. You get someone else's site at
// your project's URL, with a 200 and no error anywhere — much harder to
// read than the bind failure the second server would hit.
//
// Only types that publish a "port" (astro's dev server) are compared.
// Moodle's effective.json carries phpFpmPort, which mpd allocates and
// keeps distinct, so it is deliberately not in scope here.
//
// A warning, never a refusal: the developer may be mid-edit, or may
// intend to run only one of the two at a time.
func warnPortClash(out io.Writer, name string, effective map[string]any, s state.Store) {
	port, ok := effectivePort(effective)
	if !ok {
		return
	}
	for _, other := range s.Projects() {
		if other.Name == name {
			continue
		}
		otherPort, ok := effectivePort(project.ReadEffective(other.Name))
		if !ok || otherPort != port {
			continue
		}
		fmt.Fprintf(out, "\nWarning: '%s' also uses port %d.\n", other.Name, port)
		fmt.Fprintf(out, "  Only one of them can serve at a time, and while that one is up it\n")
		fmt.Fprintf(out, "  answers for both URLs — you would get its site at the other's address.\n")
		fmt.Fprintf(out, "  Give one a different server.port in astro.config.mjs, then re-run\n")
		fmt.Fprintf(out, "  mpd configure %s\n", name)
		return
	}
}

// effectivePort reads the frontdoor upstream port a project type wrote
// into effective.json. JSON numbers decode as float64; a string is
// accepted too, since the file is written by shell interpolation.
func effectivePort(effective map[string]any) (int, bool) {
	switch v := effective["port"].(type) {
	case float64:
		if v > 0 {
			return int(v), true
		}
	case string:
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n, true
		}
	}
	return 0, false
}

// behatEnabled reads the behat flag from effective.json, which emits it
// as a bare number (configure.sh interpolates 0 or 1).
func behatEnabled(effective map[string]any) bool {
	switch v := effective["behat"].(type) {
	case float64:
		return v == 1
	case string:
		return v == "1"
	case bool:
		return v
	}
	return false
}

// serviceEnabled reports whether an extra service is recorded as enabled.
func serviceEnabled(s state.Store, name string) bool {
	for _, entry := range s.Services() {
		if entry.Name == name {
			return entry.Enabled
		}
	}
	return false
}

// sameURLs reports whether two URL lists are identical, so a refresh that
// changes nothing does not rewrite projects.json.
//
// Order matters and that is deliberate: configure.sh emits them in a
// stable order, so a difference in order is a real difference.
func sameURLs(a, b []state.ProjectURL) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// projectVerbs are names a project may not take, because `mpd <name>
// <verb>` would become ambiguous.
var projectVerbs = map[string]bool{
	"show": true, "help": true, "create": true, "configure": true,
	"start": true, "stop": true, "delete": true, "project": true,
}

// reservedNames are names a project may not take because they live
// directly under the project DNS namespace: runtime.<zone> is the
// runtime container, *.svc.<zone> are the extra service containers,
// *.db.<zone> are the database containers, and vm.<zone> is the VM's
// own diagnostic record.
var reservedNames = map[string]bool{
	"runtime": true, "svc": true, "db": true, "vm": true,
}

var validProjectName = regexp.MustCompile(`^[a-z][a-z0-9]*(-[a-z0-9]+)*$`)

// CreateOptions carries `project create`'s flags.
type CreateOptions struct {
	Type string
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
			"(e.g. 'moodle-mebis').", name)
	}
	if projectVerbs[name] {
		return fmt.Errorf("Project name '%s' is reserved by CLI syntax. Choose another name.", name)
	}
	if reservedNames[name] {
		return fmt.Errorf("Project name '%s' is reserved by mpd's DNS naming. Choose another name.", name)
	}
	if _, exists := findProject(d.State, name); exists {
		return fmt.Errorf("Project '%s' already exists.", name)
	}

	// Type resolution, strongest evidence first: an explicit --type, then
	// what is actually in the source tree, then the project's name, then
	// moodle as mpd's overall default.
	//
	// The tree outranks the name because it is evidence rather than a
	// guess: `mpd create docs` on a checkout holding astro.config.mjs is
	// an astro project whatever the directory is called. Creating into an
	// existing tree is the normal path — `create` does not fetch source,
	// so the clone usually happened first.
	typeName := opts.Type
	if typeName == "" {
		matched := d.Assets.DetectTypeFromTree(srv.ProjectDir(name))
		if len(matched) > 1 {
			return fmt.Errorf("/srv/projects/%s looks like more than one project type (%s).\n"+
				"Say which one: mpd create %s --type=<type>",
				name, strings.Join(matched, ", "), name)
		}
		if len(matched) == 1 {
			typeName = matched[0]
			fmt.Fprintf(out, "Detected project type '%s' from /srv/projects/%s.\n", typeName, name)
		}
	}
	if typeName == "" {
		typeName = d.Assets.DetectTypeFromName(name)
	}
	if typeName == "" {
		typeName = "moodle"
	}

	// Start the runtime BEFORE touching any project state, so a failure
	// here leaves nothing half-created.
	if err := ensureRuntime(ctx, out, d, home); err != nil {
		return err
	}
	container := d.Observer.RuntimeContainer(runtime.Name)

	fmt.Fprintf(out, "\n\033[1m==> Ensuring /srv/projects/%s/\033[0m\n", name)
	if code, err := project.Exec(ctx, d.Podman, container, d.DevUser,
		"mkdir", "-p", "/srv/projects/"+name); err != nil || code != 0 {
		return fmt.Errorf("Failed to create /srv/projects/%s in the runtime.", name)
	}

	// The type's own scaffolding: seeds mpd.env from its template and
	// excludes it from git. Optional — types without the script skip.
	if cfg, ok := d.Assets.ProjectTypeConfig(typeName); ok {
		if d.Assets.HasFile(fmt.Sprintf("%s/project_types/%s/project-create.sh",
			assets.RuntimeDir, cfg.AssetsType)) {
			script := assets.TypeScript(cfg.AssetsType, "project-create.sh")
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
func ensureRuntime(ctx context.Context, out io.Writer, d ProjectDeps, home string) error {
	container := d.Observer.RuntimeContainer(runtime.Name)
	switch {
	case !d.Podman.Exists(ctx, container):
		fmt.Fprintln(out, "No runtime yet — creating...")
		return RuntimeCreate(ctx, out, d.Podman, d.State, d.Dnsmasq, d.Observer,
			d.Net, d.DevUser, d.UID, home)
	case !d.Podman.Running(ctx, container):
		return RuntimeStart(ctx, out, d.Podman, d.State, d.Dnsmasq, d.Observer,
			d.Net, d.DevUser, d.UID)
	}
	return nil
}

// ShowHelp prints the verb reference for one project — what `mpd help
// <project>` answers.
//
// Per-project rather than generic because the useful form of "what can I
// do here" names the project: the reader can copy any line as-is.
func ShowHelp(out io.Writer, project string, n net.Net) {
	fmt.Fprintf(out, "Usage: mpd <verb> %s [options...]\n", project)
	fmt.Fprintln(out, "\nVerbs:")
	fmt.Fprintf(out, "  show       %s                       project details\n", project)
	fmt.Fprintf(out, "  create     %s [--type=<type>]       (default type: moodle)\n", project)
	fmt.Fprintf(out, "  configure  %s [KEY=VALUE ...]       (e.g. MPD_DB=postgres:18, MPD_PHP_VERSION=8.4;\n", project)
	fmt.Fprintf(out, "                                              full set lives in /srv/projects/%s/mpd.env)\n", project)
	fmt.Fprintf(out, "  start      %s\n", project)
	fmt.Fprintf(out, "  stop       %s\n", project)
	fmt.Fprintf(out, "  reset      %s [--yes]               destroy the DB + /srv/data/%s/,\n", project, project)
	fmt.Fprintf(out, "                                              keep the code; then configure again\n")
	fmt.Fprintf(out, "  delete     %s [--yes]\n", project)
	fmt.Fprintln(out, "")
	fmt.Fprintf(out, "Inside /srv/projects/%s/ (or any subdirectory) the name is optional:\n", project)
	fmt.Fprintln(out, "  mpd start        mpd configure KEY=VALUE        mpd show")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "Project-type-specific operations (mdl-cron, phpunit, composer, …) are tools,")
	fmt.Fprintln(out, "not host-side verbs. SSH into the runtime and run them on PATH:")
	fmt.Fprintf(out, "  ssh user@%s\n", n.RuntimeFQDN())
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "Or forward one from the VM, from inside the project directory:")
	fmt.Fprintf(out, "  cd /srv/projects/%s && mpd run <command> [args...]\n", project)
}
