package web

import (
	"context"
	"fmt"
	"html/template"
	"os"
	"sort"
	"strings"

	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/runtime"
	"github.com/mutms/mpd/go/internal/service"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/vm"
)

// page holds the whole template set: the shell plus one named template
// per section. A section is addressable on its own
// (`page.ExecuteTemplate(w, "services", …)`), which is what htmx fetches.
var page = template.Must(template.New("page").Parse(
	shellHTML + projectsHTML + servicesHTML + databasesHTML + infraHTML))

// View is what the templates render. Everything on it is derived here,
// not in the template: a template that can only range over prepared
// values cannot accidentally grow logic.
type View struct {
	Zone      string
	Host      string
	Version   string
	Projects  []ProjectRow
	Services  []ServiceRow
	Databases []DatabaseRow
	Infra     []InfraRow
}

// ProjectRow shows one project. Status is the single lifecycle word from
// state.Project.Status ("started"/"stopped"/"not initialised"); Running is
// just whether that word is "started", used to colour the badge. There is
// no separate live-observation column — a start that does not fully come
// up records itself stopped, so the stored status is the honest one.
type ProjectRow struct {
	Name    string
	Status  string
	Running bool
	Type    string
	Runtime string
	URL     string
	// Connection details for the project's database. The portal is the
	// only place these are written down: db.CreateFor derives all three
	// from the project name (docs/security.md calls it a dev-only
	// choice), so nothing stores them and nothing else prints them.
	DBHost string
	DBUser string
	DBPass string
	// Links are per-project links contributed by enabled, running extra
	// services (service.Service.ProjectLinks) — Adminer's prefilled
	// connection, and whatever future services offer. Only populated
	// when the pieces the link needs are actually up: a link that leads
	// to a connection error is worse than no link.
	Links []service.Link
}

// InfraRow is one VM-integral infrastructure piece (the runtime
// container, dnsmasq, portal) as the page shows it — always-on parts of
// mpd itself, distinct from the optional service containers.
type InfraRow struct {
	Name    string
	Status  string
	Running bool
	Access  string
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
	v := View{Zone: d.Net.Zone(), Host: host, Version: d.Version}
	projects := d.State.Projects()

	// Gathered once and shared: the project rows need to know whether a
	// database is up before offering to open it, and asking podman per
	// project would both duplicate work and let rows disagree.
	dbUp := runningDatabases(ctx, d)
	live := liveServices(ctx, d)

	v.Projects = projectRows(ctx, d, projects, dbUp, live)
	v.Services = serviceRows(ctx, d, live)
	v.Databases = databaseRows(ctx, d, projects)
	v.Infra = infraRows(ctx, d)
	return v
}

func projectRows(ctx context.Context, d Deps, projects []state.Project,
	dbUp map[string]bool, live map[string]string) []ProjectRow {

	rows := make([]ProjectRow, 0, len(projects))
	for _, p := range projects {
		rows = append(rows, ProjectRow{
			Name:    p.Name,
			Status:  p.Status(),
			Running: p.Status() == "started",
			Type:    dash(p.Type),
			Runtime: dash(p.RuntimeName),
			URL:     p.MainURL(),
			DBHost:  dbHost(d, p),
			DBUser:  p.Name,
			DBPass:  p.Name,
			Links:   projectLinks(d, p, dbUp, live),
		})
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Name < rows[j].Name })
	return rows
}

// projectLinks collects what every enabled-and-running extra service
// offers for one project, gated on the project's database being up —
// the links all point at database views today.
func projectLinks(d Deps, p state.Project, dbUp map[string]bool, live map[string]string) []service.Link {
	if !dbUp[p.DatabaseID] {
		return nil
	}
	info := service.ProjectInfo{
		Name:     p.Name,
		DBEngine: p.DatabaseEngine,
		DBHost:   dbHost(d, p),
		DBUser:   p.Name,
		DBName:   p.Name,
	}
	var links []service.Link
	for _, svc := range service.All() {
		if live[svc.Name] != "running" {
			continue
		}
		links = append(links, svc.ProjectLinks(d.Net, info)...)
	}
	return links
}

// runtimeInfraRow is the unified runtime container as an Infra row: one
// fixed, always-on piece of mpd, so it lives with dnsmasq and the portal
// rather than in a section of its own.
func runtimeInfraRow(ctx context.Context, d Deps) InfraRow {
	// No Access value: how to reach the runtime is the host-side
	// orchestrator's business, not the dashboard's.
	row := InfraRow{
		Name:   runtime.Name,
		Status: "missing (run mpd --vm-setup)",
		Access: "—",
	}
	// Filter on the presence of mpd.runtime, not on a type label: the
	// runtime container carries mpd.runtime=runtime and there is no
	// mpd.type=runtime, so matching a value would find nothing.
	for _, item := range d.Podman.Ps(ctx, "label=mpd.runtime") {
		if item.Label("mpd.name") != runtime.Name {
			continue
		}
		row.Running = item.State == "running"
		row.Status = "stopped"
		if row.Running {
			row.Status = "running"
		}
	}
	return row
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

// infraRows lists the VM-integral infrastructure: the runtime container
// plus the systemd units on the VM, always on, distinct from the
// optional service containers.
func infraRows(ctx context.Context, d Deps) []InfraRow {
	rows := []InfraRow{runtimeInfraRow(ctx, d)}
	for _, inf := range vm.InfraServices() {
		row := InfraRow{Name: inf.Name, Status: "stopped"}
		switch inf.Name {
		case "dnsmasq":
			row.Access = fmt.Sprintf("DNS resolver (%s:53)", d.Net.Gateway())
		case "portal":
			row.Access = fmt.Sprintf("https://%s/", d.Net.Zone())
		}
		if d.UnitActive != nil && d.UnitActive(ctx, inf.Unit, inf.UnitUser) {
			row.Running = true
			row.Status = "running"
		}
		rows = append(rows, row)
	}
	return rows
}

// liveServices maps each extra service name to its container state
// ("running", "exited", …); absent means not installed.
func liveServices(ctx context.Context, d Deps) map[string]string {
	live := map[string]string{}
	for _, item := range d.Podman.Ps(ctx, podmanServiceFilter) {
		if name := item.Label("mpd.name"); name != "" {
			live[name] = item.State
		}
	}
	return live
}

// serviceRows lists the OPTIONAL extra services with their intent
// (services.json) joined against what podman actually has.
func serviceRows(ctx context.Context, d Deps, live map[string]string) []ServiceRow {
	intent := map[string]bool{}
	installed := map[string]bool{}
	for _, entry := range d.State.Services() {
		intent[entry.Name] = entry.Enabled
		installed[entry.Name] = true
	}

	var rows []ServiceRow
	for _, svc := range service.All() {
		row := ServiceRow{
			Name:   svc.Name,
			IP:     svc.IP(d.Net),
			DNS:    svc.DNS(d.Net),
			Access: svc.AccessHint(d.Net),
			Status: "not installed",
		}
		switch {
		case live[svc.Name] == "running":
			row.Running = true
			row.Status = "running"
		case installed[svc.Name] && !intent[svc.Name]:
			row.Status = "disabled"
		case installed[svc.Name]:
			row.Status = "stopped"
		}
		if !installed[svc.Name] {
			row.Access = "mpd --service-enable=" + svc.Name
		}
		rows = append(rows, row)
	}
	return rows
}

// podmanServiceFilter matches the label every mpd extra service
// container carries. Mirrors cli.serviceFilter; duplicated rather than
// exported to keep the page from importing the CLI layer.
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

func dash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}
