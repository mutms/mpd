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
	"github.com/mutms/mpd/go/internal/service"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/vm"
)

// ProjectDeps bundles what the project verbs need.
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

// ProjectStart configures a project and brings it up in one verb. It
// always reconciles first — settings land in mpd.env, configure.sh
// runs, database, cert and DNS follow — so `mpd start` after an mpd.env
// edit makes reality match the file. Autostart is recorded only after
// every step succeeds, so a failed start never claims to run.
func ProjectStart(ctx context.Context, out io.Writer, name string, settings []string,
	d ProjectDeps) error {

	if _, found := findProject(d.State, name); !found {
		return fmt.Errorf("Project '%s' not found. Create it: mpd init %s", name, name)
	}

	url, err := startProject(ctx, out, name, settings, d)
	if err != nil {
		// A start that did not fully succeed is recorded stopped — the
		// reverse hides a broken site behind a green status.
		markStopped(out, d.State, name)
		return err
	}

	// Mark autostart only after every step succeeded. Re-read first:
	// reconcileProject persisted its own view of the entry.
	if entry, found := findProject(d.State, name); found {
		entry.Autostart = true
		if err := d.State.UpsertProject(entry); err != nil {
			return err
		}
	}

	Ok(out, "'%s' is running.", name)
	if url != "" {
		fmt.Fprintf(out, "  %s\n", url)
	}
	return nil
}

// startProject configures a project and runs its start lifecycle,
// returning the URL to print. It never touches the autostart flag —
// ProjectStart owns that.
func startProject(ctx context.Context, out io.Writer, name string, settings []string,
	d ProjectDeps) (string, error) {

	// Configure first; it writes the URLs the start tail
	// below needs.
	if err := reconcileProject(ctx, out, name, settings, d); err != nil {
		return "", err
	}

	entry, found := findProject(d.State, name)
	if !found {
		return "", fmt.Errorf("Project '%s' not found after configure.", name)
	}
	ev := hookProject(entry, d)

	// Pre-start: the DB is up, project setup has not run.
	// Failure aborts — a failed precondition should not come up.
	if err := hooks.Fire(ctx, out, hooks.ProjectPreStart(ctx, ev, d.Podman), "start", d.Podman); err != nil {
		return "", err
	}

	// Cert and DNS are already provisioned; go straight to the type's
	// setup script.
	cfg, hasType := d.Assets.ProjectTypeConfig(entry.Type)
	if hasType && d.Assets.HasTypeFile(cfg.AssetsType, "project-setup.sh") {
		fmt.Fprintf(out, "\n\033[1m==> Setting up '%s'\033[0m\n", name)
		script := assets.TypeScript(cfg.AssetsType, "project-setup.sh")
		code, err := project.Exec(ctx, "bash", script, name)
		if err != nil || code != 0 {
			return "", fmt.Errorf("project-setup.sh failed.")
		}
	}

	// Post-start: fully live. Failures warn but never undo the start.
	if err := hooks.Fire(ctx, out, hooks.ProjectPostStart(ctx, ev, d.Podman), "start", d.Podman); err != nil {
		fmt.Fprintf(out, "Warning: %v\n", err)
	}

	url := entry.MainURL()
	if !hasType || cfg.WaitForURL {
		waitForURL(ctx, out, url)
	}
	return url, nil
}

// markStopped records a project as stopped, best-effort: the caller is
// already returning the real start error.
func markStopped(out io.Writer, s state.Store, name string) {
	entry, found := findProject(s, name)
	if !found || !entry.Autostart {
		return
	}
	entry.Autostart = false
	if err := s.UpsertProject(entry); err != nil {
		fmt.Fprintf(out, "Warning: could not record '%s' as stopped: %v\n", name, err)
	}
}

// waitForURL blocks until the project's main URL answers, up to ~30s.
// The frontdoor updates out of band (the project caddy watches
// /srv/meta by inotify), so without this wait mpd prints "is running"
// while the URL still 502s. Last and non-fatal: everything mpd owns is
// already done and persisted, so Ctrl-C or a timeout here loses nothing.
func waitForURL(ctx context.Context, out io.Writer, url string) {
	if url == "" {
		return
	}
	client, err := trustingClient()
	if err != nil {
		fmt.Fprintf(out, "  Warning: cannot verify %s: %v\n", url, err)
		return
	}

	// Anything below 500 means the vhost is wired to a live backend; a
	// redirect counts and is not followed.
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
// nothing else. Verification is not skipped: after a CA rotation caddy
// can serve a certificate nothing trusts any more, and an
// InsecureSkipVerify probe would report that broken project as ready.
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

// ProjectStop takes a project down. It stops neither the frontdoor nor
// the database — mpd is demand-driven (see docs/hooks.md), and
// reclaiming idle resources is `mpd --gc`'s job.
func ProjectStop(ctx context.Context, out io.Writer, name string, d ProjectDeps) error {
	entry, found := findProject(d.State, name)
	if !found {
		return fmt.Errorf("Project '%s' not found. Create it: mpd init %s", name, name)
	}

	// Idempotent: every step is best-effort, and the project ends up
	// recorded stopped either way.
	ev := hookProject(entry, d)

	// Pre-stop: still live, so hooks can drain work or flush caches.
	// Failure logs, never blocks — you cannot fail to stop.
	if err := hooks.Fire(ctx, out, hooks.ProjectPreStop(ctx, ev, d.Podman), "stop", d.Podman); err != nil {
		fmt.Fprintf(out, "Warning: %v\n", err)
	}

	// A type may ship project-stop.sh for whatever stopping means to it.
	// Optional and best-effort: the project ends up stopped regardless.
	if cfg, ok := d.Assets.ProjectTypeConfig(entry.Type); ok &&
		d.Assets.HasTypeFile(cfg.AssetsType, "project-stop.sh") {
		script := assets.TypeScript(cfg.AssetsType, "project-stop.sh")
		_, _ = project.Exec(ctx, "bash", script, name)
	}

	entry.Autostart = false
	if err := d.State.UpsertProject(entry); err != nil {
		return err
	}

	// The DNS record stays: it belongs to the project being configured,
	// not to it being up. Only delete withdraws it.
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

// hookProject builds the hook-facing view of a project. No project-type
// fields.
func hookProject(entry state.Project, d ProjectDeps) hooks.Project {
	return hooks.Project{
		Name:      entry.Name,
		DBEngine:  entry.DatabaseEngine,
		DBVersion: entry.DatabaseVersion,
	}
}

// ProjectDelete removes a project and everything scoped to it: source
// tree, dataroot, meta, its database inside the engine, and its DNS
// record. The prompt says so before asking.
func ProjectDelete(ctx context.Context, out io.Writer, in io.Reader, name string,
	d ProjectDeps, assumeYes bool) error {

	entry, found := findProject(d.State, name)
	if !found {
		return fmt.Errorf("Project '%s' not found.", name)
	}
	typeStr := entry.Type
	if typeStr == "" {
		typeStr = "(not detected)"
	}
	fmt.Fprintf(out, "Project:  %s\n", name)
	fmt.Fprintf(out, "Type:     %s\n", typeStr)
	fmt.Fprintf(out, "Source:   /srv/projects/%s/\n", name)
	fmt.Fprintln(out, "This will remove the DB, dataroot, source tree, and all config files.")
	fmt.Fprintf(out, "To keep the code and start over instead, use `mpd reset %s`.\n", name)

	if !assumeYes && !promptName(out, in, name, "deletion") {
		fmt.Fprintln(out, "Aborted.")
		return nil
	}

	// Stop first so the type's stop path runs before its files go.
	if entry.Autostart {
		if err := ProjectStop(ctx, out, name, d); err != nil {
			fmt.Fprintf(out, "Warning: stop failed, continuing with delete: %v\n", err)
		}
	}

	if entry.Configured {
		if cfg, ok := d.Assets.ProjectTypeConfig(entry.Type); ok {
			script := assets.TypeScript(cfg.AssetsType, "project-delete.sh")
			_, _ = project.Exec(ctx, "bash", script, name)
		}
	}

	// Drop the project's database inside its engine — not the engine
	// itself, which other projects share.
	if entry.DatabaseEngine != "" {
		dbContainer := db.ContainerName(entry.DatabaseEngine, entry.DatabaseVersion)
		if d.Podman.Running(ctx, dbContainer) {
			if err := db.Drop(ctx, out, entry.DatabaseEngine, dbContainer, name, d.Podman); err != nil {
				fmt.Fprintf(out, "Warning: %v\n", err)
			}
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
	// Recomputing after the state change is what retracts the project's
	// names.
	if err := PublishDNS(ctx, out, d.Dnsmasq, d.Net, d.State, false); err != nil {
		return err
	}

	Ok(out, "Project '%s' deleted.", name)
	return nil
}

// ProjectReset throws away a project's derived data — database,
// /srv/data/<name>/, /srv/meta/<name>/ including the certificate, DNS
// record — and keeps /srv/projects/<name>/ (code, mpd.env, config.php).
// The result is exactly what `create` writes, deliberately not
// configured: the next start re-reads mpd.env, which is what makes
// switching MPD_DB work. The shared engine container is left running.
func ProjectReset(ctx context.Context, out io.Writer, in io.Reader, name string,
	d ProjectDeps, assumeYes bool) error {

	entry, found := findProject(d.State, name)
	if !found {
		return fmt.Errorf("Project '%s' not found.", name)
	}
	dbStr := entry.DatabaseID
	if dbStr == "" {
		dbStr = "(none)"
	}
	fmt.Fprintf(out, "Project:  %s\n", name)
	fmt.Fprintf(out, "Type:     %s\n", orDash(entry.Type))
	fmt.Fprintf(out, "Database: %s\n", dbStr)
	fmt.Fprintf(out, "Keeps:    /srv/projects/%s/ (code, mpd.env, config.php)\n", name)
	fmt.Fprintf(out, "Destroys: the '%s' database and everything in /srv/data/%s/\n", name, name)
	fmt.Fprintf(out, "Leaves '%s' not configured — run `mpd start %s` next.\n", name, name)

	if !assumeYes && !promptName(out, in, name, "reset") {
		fmt.Fprintln(out, "Aborted.")
		return nil
	}

	// Stop first, so the type's stop path and pre-stop hooks run
	// against a live project.
	if entry.Autostart {
		if err := ProjectStop(ctx, out, name, d); err != nil {
			fmt.Fprintf(out, "Warning: stop failed, continuing with reset: %v\n", err)
		}
	}

	// The type's teardown: reset is a re-scaffold, so tear down as
	// completely as delete would — configure.sh builds it all back.
	if entry.Configured {
		if cfg, ok := d.Assets.ProjectTypeConfig(entry.Type); ok {
			script := assets.TypeScript(cfg.AssetsType, "project-delete.sh")
			_, _ = project.Exec(ctx, "bash", script, name)
		}
	}

	// Drop the project's database — never the engine itself.
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

	fmt.Fprintf(out, "\n\033[1m==> Clearing /srv/data/%s/\033[0m\n", name)
	if err := srv.RemoveContents(ctx, srv.DataDir(name)); err != nil {
		return err
	}
	// Generated metadata, certificate included: configure rebuilds all
	// of it from mpd.env.
	if err := srv.Remove(ctx, srv.MetaDir(name)); err != nil {
		return err
	}

	// Exactly what ProjectCreate writes, assembled field by field so a
	// field added to state.Project later cannot survive a reset.
	if err := d.State.UpsertProject(state.Project{
		Name: entry.Name,
		Type: entry.Type,
	}); err != nil {
		return err
	}
	// The entry has no URLs now, so the recompute retracts the
	// project's names.
	if err := PublishDNS(ctx, out, d.Dnsmasq, d.Net, d.State, false); err != nil {
		return err
	}

	fmt.Fprintln(out, "")
	Ok(out, "Project '%s' reset — code kept, data gone, not configured.", name)
	fmt.Fprintf(out, "  Edit /srv/projects/%s/mpd.env (e.g. MPD_DB) if needed, then:\n", name)
	fmt.Fprintf(out, "    mpd start %s\n", name)
	return nil
}

// reconcileProject is the configure half of `mpd start`. The order is a
// data dependency chain: mutations land in mpd.env, configure.sh emits
// effective.json + urls.json, dbTag from effective.json provisions the
// database, URLs drive cert and DNS. It leaves the frontdoor up for
// the start tail.
func reconcileProject(ctx context.Context, out io.Writer, name string, args []string,
	d ProjectDeps) error {

	entry, found := findProject(d.State, name)
	if !found {
		return fmt.Errorf("Project '%s' not found. Create it: mpd init %s", name, name)
	}

	mutations, err := project.ParseMutations(args, func(tag string) error {
		_, _, err := db.ParseTag(tag)
		return err
	})
	if err != nil {
		return err
	}

	// Type is immutable — changing it would mean re-scaffolding, which
	// is `init`'s job.
	if entry.Type == "" {
		return fmt.Errorf("Project type is not set for '%s'.\n"+
			"Create a new project to choose a type (default: moodle).", name)
	}
	entry.Configured = true

	if len(mutations) > 0 {
		fmt.Fprintf(out, "\n\033[1m==> Updating /srv/projects/%s/mpd.env\033[0m\n", name)
		if err := project.ApplyMutations("/srv/projects/"+name+"/mpd.env", mutations); err != nil {
			return err
		}
	}

	// Write project.json first: source-mpd-env.sh reads the type from
	// it to locate the mpd-defaults.env layers.
	if err := project.WriteMeta(ctx, d.Podman, d.UID, entry); err != nil {
		return err
	}

	cfg, hasType := d.Assets.ProjectTypeConfig(entry.Type)
	if hasType {
		script := assets.TypeScript(cfg.AssetsType, "scripts/configure.sh")
		code, err := project.Exec(ctx, "bash", script, name)
		if err != nil || code != 0 {
			return fmt.Errorf("configure.sh failed for project '%s'.", name)
		}
	}

	// Only configure.sh can resolve dbTag — mpd reads the answer rather
	// than duplicating the env cascade.
	effective := project.ReadEffective(name)
	dbTag, _ := effective["dbTag"].(string)

	warnPortClash(out, name, effective, d.State)

	// Start the services the project declares (MPD_REQUIRE_SERVICES,
	// resolved by configure.sh into effective.json) on demand, without
	// setting the sticky autostart intent.
	for _, svcName := range requiredServices(effective) {
		if _, ok := service.Find(svcName); !ok {
			fmt.Fprintf(out, "  Warning: MPD_REQUIRE_SERVICES lists unknown service '%s' — skipping.\n", svcName)
			continue
		}
		if err := EnsureService(ctx, out, svcName, d.Podman, d.State,
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
	} else {
		// Clear stale DB fields: a project that dropped MPD_DB must stop
		// claiming a database it no longer uses.
		entry.DatabaseEngine, entry.DatabaseVersion, entry.DatabaseID = "", "", ""
	}

	entry.URLs, _ = project.ReadURLs(name)
	// Autostart is left untouched here: start and stop own it.
	if err := project.WriteMeta(ctx, d.Podman, d.UID, entry); err != nil {
		return err
	}
	if err := d.State.UpsertProject(entry); err != nil {
		return err
	}

	if err := project.EnsureCert(ctx, out, name, entry.URLs, d.Net, d.Podman, d.UID); err != nil {
		return err
	}

	// DNS is published before the start tail: a configured project is an
	// addressable one, the only rule that works for types whose server
	// the developer starts by hand (astro). One recompute covers the
	// project's names and the database created above.
	if err := PublishDNS(ctx, out, d.Dnsmasq, d.Net, d.State, false); err != nil {
		return err
	}

	// Reclaiming an idle database is `mpd --gc`'s job.
	return nil
}

// warnPortClash reports another project claiming the same frontdoor
// port. The failure is otherwise invisible: whichever server is up
// answers for both names with a 200. Only types that publish "port"
// (astro) are compared — Moodle's phpFpmPort is mpd-allocated and
// distinct. A warning, never a refusal.
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
		fmt.Fprintf(out, "  mpd start %s\n", name)
		return
	}
}

// effectivePort reads the frontdoor upstream port from effective.json.
// A string is accepted too — the file is written by shell interpolation.
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

// requiredServices returns the names configure.sh emitted into
// effective.json for MPD_REQUIRE_SERVICES; nil when missing or
// malformed.
func requiredServices(effective map[string]any) []string {
	raw, ok := effective["requireServices"].([]any)
	if !ok {
		return nil
	}
	var names []string
	for _, v := range raw {
		if str, ok := v.(string); ok && str != "" {
			names = append(names, str)
		}
	}
	return names
}

// sameURLs reports whether two URL lists are identical, so a refresh
// that changes nothing does not rewrite projects.json. Order matters:
// configure.sh emits a stable order.
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
	"status": true, "help": true, "init": true, "reset": true,
	"start": true, "stop": true, "delete": true, "run": true,
	"project": true,
	// Aliases resolve as commands too: "rm" (delete), "ls" (list).
	"rm": true, "ls": true,
}

// reservedNames are names a project may not take because they live
// directly under the project DNS namespace (svc, db, vm records).
var reservedNames = map[string]bool{
	"svc": true, "db": true, "vm": true,
}

var validProjectName = regexp.MustCompile(`^[a-z][a-z0-9]*(-[a-z0-9]+)*$`)

// CreateOptions carries `project create`'s flags.
type CreateOptions struct {
	Type string
}

// ProjectCreate scaffolds a new project — the `mpd init` verb. It does
// not configure: init lays down the tree and a seeded mpd.env, then
// stops so the developer can edit the file before `mpd start` acts on
// it.
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

	// Type resolution, strongest evidence first: explicit --type, then
	// the source tree, then the name, then moodle. The tree outranks the
	// name because it is evidence rather than a guess.
	typeName := opts.Type
	if typeName == "" {
		matched := d.Assets.DetectTypeFromTree(srv.ProjectDir(name))
		if len(matched) > 1 {
			return fmt.Errorf("/srv/projects/%s looks like more than one project type (%s).\n"+
				"Say which one: mpd init %s --type=<type>",
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

	fmt.Fprintf(out, "\n\033[1m==> Ensuring /srv/projects/%s/\033[0m\n", name)
	if err := srv.MkdirAll(srv.ProjectDir(name)); err != nil {
		return fmt.Errorf("Failed to create /srv/projects/%s: %v", name, err)
	}

	// The type's own scaffolding; optional — types without the script
	// skip.
	if cfg, ok := d.Assets.ProjectTypeConfig(typeName); ok {
		if d.Assets.HasFile(fmt.Sprintf("%s/project_types/%s/project-create.sh",
			assets.VMDir, cfg.AssetsType)) {
			script := assets.TypeScript(cfg.AssetsType, "project-create.sh")
			fmt.Fprintf(out, "\n\033[1m==> Scaffolding project from %s template\033[0m\n", typeName)
			if code, err := project.Exec(ctx, "bash", script, name); err != nil || code != 0 {
				return fmt.Errorf("project-create.sh failed for project '%s'.", name)
			}
		}
	}

	// Register only after scaffolding succeeds; a failure leaves the
	// directory for the developer to inspect. Not Configured and not
	// Autostart: Status reports "not initialised" until the first start.
	if err := d.State.UpsertProject(state.Project{
		Name: name, Type: typeName,
	}); err != nil {
		return err
	}

	fmt.Fprintln(out, "")
	Ok(out, "Project '%s' scaffolded.", name)
	fmt.Fprintf(out, "  Edit /srv/projects/%s/mpd.env if needed, then:\n", name)
	fmt.Fprintf(out, "    mpd start %s\n", name)
	return nil
}

// ShowHelp prints the verb reference for one project, named so the
// reader can copy any line as-is.
func ShowHelp(out io.Writer, project string, n net.Net) {
	fmt.Fprintf(out, "Usage: mpd <verb> %s [options...]\n", project)
	fmt.Fprintln(out, "\nVerbs:")
	fmt.Fprintf(out, "  status     %s [--json]              project details (--json for scripts)\n", project)
	fmt.Fprintf(out, "  init       %s [--type=<type>]       scaffold mpd.env (default type: moodle)\n", project)
	fmt.Fprintf(out, "  start      %s [KEY=VALUE ...]       configure + start (e.g. MPD_DB=postgres:18,\n", project)
	fmt.Fprintf(out, "                                              MPD_PHP_VERSION=8.4; full set lives in\n")
	fmt.Fprintf(out, "                                              /srv/projects/%s/mpd.env)\n", project)
	fmt.Fprintf(out, "  stop       %s\n", project)
	fmt.Fprintf(out, "  reset      %s [--yes]               destroy the DB + /srv/data/%s/,\n", project, project)
	fmt.Fprintf(out, "                                              keep the code; then start again\n")
	fmt.Fprintf(out, "  delete     %s [--yes]               (alias: rm)\n", project)
	fmt.Fprintln(out, "")
	fmt.Fprintf(out, "Inside /srv/projects/%s/ (or any subdirectory) the name is optional:\n", project)
	fmt.Fprintln(out, "  mpd start        mpd start KEY=VALUE        mpd status")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "Project-type-specific operations (mdl-cron, phpunit, composer, …) are tools,")
	fmt.Fprintln(out, "not verbs. They are on PATH — run them from the project directory:")
	fmt.Fprintf(out, "  cd /srv/projects/%s && mdl-cron\n", project)
}
