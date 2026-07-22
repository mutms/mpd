package web

import (
	"context"
	"fmt"
	"html/template"
	"net/url"
	"os"
	"sort"
	"strings"

	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/service"
	"github.com/mutms/mpd/go/internal/state"
)

// page holds the whole template set: the shell plus one named template
// per section. A section is addressable on its own
// (`page.ExecuteTemplate(w, "services", …)`), which is what htmx fetches.
var page = template.Must(template.New("page").Parse(
	shellHTML + projectsHTML + runtimesHTML + databasesHTML + servicesHTML))

// View is what the templates render. Everything on it is derived here,
// not in the template: a template that can only range over prepared
// values cannot accidentally grow logic.
type View struct {
	Zone      string
	Host      string
	Projects  []ProjectRow
	Runtimes  []RuntimeRow
	Databases []DatabaseRow
	Services  []ServiceRow
}

// ProjectRow carries both because they answer different questions:
// Requested is persisted intent, Status is a live observation
// (current.Observer). Rendering one twice would hide exactly the
// disagreement worth seeing — "requested running, status stopped" is the
// interesting case.
type ProjectRow struct {
	Name      string
	Requested string
	Status    string
	Running   bool
	Type      string
	Runtime   string
	URL       string
	// Connection details for the project's database. The portal is the
	// only place these are written down: db.CreateFor derives all three
	// from the project name (docs/SECURITY.md calls it a dev-only
	// choice), so nothing stores them and nothing else prints them.
	DBHost string
	DBUser string
	DBPass string
	// AdminerURL opens Adminer with this project's connection prefilled.
	// Empty unless both the database and Adminer are up — a link that
	// leads to a connection error is worse than no link.
	AdminerURL string
}

type RuntimeRow struct {
	Name      string
	Requested string
	Status    string
	Running   bool
	Created   bool
	IP        string
	DNS       string
	Projects  int
}

type DatabaseRow struct {
	Name     string
	Engine   string
	Status   string
	Running  bool
	DNS      string
	Projects string
}

// ServiceRow is one always-on service as the page shows it.
type ServiceRow struct {
	Name    string
	Status  string
	Running bool
	IP      string
	DNS     string
	Access  string
}

// pageData assembles the view from mpd's own typed state.
//
// Container states come from a handful of `podman ps` calls rather than
// an inspect per item: per-item calls race something restarting
// mid-render and report a mix of before and after.
func pageData(ctx context.Context, d Deps) View {
	host, _ := os.Hostname()
	v := View{Zone: d.Net.Zone(), Host: host}
	projects := d.State.Projects()

	// Gathered once and shared: the project rows need to know whether a
	// database is up before offering to open it, and asking podman per
	// project would both duplicate work and let rows disagree.
	dbUp := runningDatabases(ctx, d)
	adminerUp := containerRunning(ctx, d, "adminer")

	v.Projects = projectRows(ctx, d, projects, dbUp, adminerUp)
	v.Runtimes = runtimeRows(ctx, d, projects)
	v.Databases = databaseRows(ctx, d, projects)
	v.Services = serviceRows(ctx, d)
	return v
}

func projectRows(ctx context.Context, d Deps, projects []state.Project,
	dbUp map[string]bool, adminerUp bool) []ProjectRow {

	rows := make([]ProjectRow, 0, len(projects))
	for _, p := range projects {
		current := string(d.Observer.Project(ctx, p))
		rows = append(rows, ProjectRow{
			Name:      p.Name,
			Requested: dash(p.Requested),
			Status:    dash(current),
			Running:   current == "running",
			Type:      dash(p.Type),
			Runtime:   dash(p.RuntimeName),
			URL:       p.MainURL(),
			DBHost:    dbHost(d, p),
			DBUser:    p.Name,
			DBPass:    p.Name,
			AdminerURL: adminerURL(d, p.DatabaseEngine, dbHost(d, p),
				p.Name, p.Name, dbUp[p.DatabaseID] && adminerUp),
		})
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Name < rows[j].Name })
	return rows
}

// runtimeRows lists runtimes that exist AND runtime types the assets tree
// offers but that have never been created — "available" is a useful
// answer to "what could I run this in?".
func runtimeRows(ctx context.Context, d Deps, projects []state.Project) []RuntimeRow {
	created := map[string]podman.PsItem{}
	// Filter on the presence of mpd.runtime, not on a type label: runtime
	// containers carry mpd.runtime=<name> and there is no
	// mpd.type=runtime, so matching a value finds nothing at all and
	// every runtime renders as "available".
	for _, item := range d.Podman.Ps(ctx, "label=mpd.runtime") {
		name := item.Label("mpd.name")
		if name == "" {
			name = item.Name()
		}
		if name != "" {
			created[name] = item
		}
	}

	names := map[string]bool{}
	for name := range created {
		names[name] = true
	}
	for _, name := range d.Assets.RuntimeNames() {
		names[name] = true
	}

	counts := state.ProjectsByRuntime(projects)
	rows := make([]RuntimeRow, 0, len(names))
	for name := range names {
		row := RuntimeRow{
			Name:      name,
			Requested: "—",
			Status:    "available",
			IP:        "—",
			DNS:       "—",
			Projects:  counts[name],
		}
		if item, ok := created[name]; ok {
			row.Created = true
			row.IP = dash(item.Label("mpd.ip"))
			row.DNS = d.Net.Runtime(name)
			row.Running = item.State == "running"
			row.Status = "stopped"
			if row.Running {
				row.Status = "running"
			}
			// Persisted intent drives reconciliation; live observation
			// drives what is shown as current.
			if entry, ok := d.State.Runtime(name); ok && entry.Requested != "" {
				row.Requested = entry.Requested
			}
		}
		rows = append(rows, row)
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Name < rows[j].Name })
	return rows
}

func databaseRows(ctx context.Context, d Deps, projects []state.Project) []DatabaseRow {
	byDB := state.ProjectNamesByDatabase(projects)

	var rows []DatabaseRow
	for _, item := range d.Podman.Ps(ctx, "label=mpd.type=db") {
		engine := label(item, "mpd.db.engine", "-")
		version := label(item, "mpd.db.version", "-")
		id := item.Label("mpd.name")
		if id == "" {
			id = engine + "-" + strings.ReplaceAll(version, ".", "-")
		}
		row := DatabaseRow{
			Name:     id,
			Engine:   fmt.Sprintf("%s:%s", engine, version),
			Status:   "stopped",
			Running:  item.State == "running",
			DNS:      d.Net.DB(id),
			Projects: "—",
		}
		if row.Running {
			row.Status = "running"
		}
		if names, ok := byDB[id]; ok {
			row.Projects = strings.Join(names, ", ")
		}
		rows = append(rows, row)
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Name < rows[j].Name })
	return rows
}

func serviceRows(ctx context.Context, d Deps) []ServiceRow {
	stateByContainer := map[string]string{}
	for _, item := range d.Podman.Ps(ctx, podmanServiceFilter) {
		if name := item.Name(); name != "" {
			stateByContainer[name] = item.State
		}
	}

	var rows []ServiceRow
	for _, svc := range service.All() {
		row := ServiceRow{
			Name:   svc.Name,
			IP:     svc.IP(d.Net),
			DNS:    svc.DNS(d.Net),
			Access: svc.AccessHint(d.Net),
			Status: "not created",
		}
		switch {
		case svc.Unit != "":
			// Runs on the VM under systemd; podman has never heard of it.
			row.Running = d.UnitActive != nil && d.UnitActive(ctx, svc.Unit, svc.UnitUser)
			row.Status = "stopped"
		case stateByContainer[svc.Container] != "":
			row.Running = stateByContainer[svc.Container] == "running"
			row.Status = "stopped"
		}
		if row.Running {
			row.Status = "running"
		}
		rows = append(rows, row)
	}
	return rows
}

// podmanServiceFilter matches the label every mpd service container
// carries. Mirrors cli.serviceFilter; duplicated rather than exported to
// keep the page from importing the CLI layer.
//
// The compose label, not mpd.type: dnsmasq and the portal predate the
// mpd.* label set and carry only this one, so filtering on mpd.type
// would silently report them as not created.
const podmanServiceFilter = "label=com.docker.compose.project=mpd-service"

func label(item podman.PsItem, key, fallback string) string {
	if v := item.Label(key); v != "" {
		return v
	}
	return fallback
}

// dbHost is where the project's database answers: the DB container's own
// name in this VM's zone. Empty when the project has no database yet,
// which is every project between `create` and `configure`.
func dbHost(d Deps, p state.Project) string {
	if p.DatabaseID == "" {
		return ""
	}
	return d.Net.DB(p.DatabaseID)
}

// runningDatabases reports which DB containers are up, keyed by the id
// projects refer to them by.
func runningDatabases(ctx context.Context, d Deps) map[string]bool {
	up := map[string]bool{}
	for _, item := range d.Podman.Ps(ctx, "label=mpd.type=db") {
		if id := item.Label("mpd.name"); id != "" {
			up[id] = item.State == "running"
		}
	}
	return up
}

func containerRunning(ctx context.Context, d Deps, serviceName string) bool {
	svc, ok := service.Find(serviceName)
	if !ok {
		return false
	}
	for _, item := range d.Podman.Ps(ctx, podmanServiceFilter) {
		if item.Name() == svc.Container {
			return item.State == "running"
		}
	}
	return false
}

// adminerURL builds a prefilled Adminer link.
//
// Adminer takes the driver as the parameter NAME, not a value: postgres
// is `?pgsql=<host>`, while MySQL and MariaDB are `?server=<host>`. Get
// that wrong and Adminer shows its own login form with nothing filled
// in, which looks like the link is broken rather than mistyped.
func adminerURL(d Deps, engine, host, user, db string, offer bool) string {
	if !offer || host == "" {
		return ""
	}
	driver := "server"
	if engine == "postgres" {
		driver = "pgsql"
	}
	q := url.Values{}
	q.Set(driver, host)
	q.Set("username", user)
	if db != "" {
		q.Set("db", db)
	}
	return fmt.Sprintf("https://%s/?%s", d.Net.Service("adminer"), q.Encode())
}

func dash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}
