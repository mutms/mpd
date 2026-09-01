package web

import (
	"context"
	"fmt"
	"html/template"
	"os"
	"sort"
	"strings"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/service"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/vm"
)

// page holds the whole template set: the shell plus one named template
// per section, so htmx can fetch a section on its own.
var page = template.Must(template.New("page").Parse(
	shellHTML + projectsHTML + servicesHTML + databasesHTML + infraHTML))

// View is what the templates render. Everything is derived here, never
// in the template.
type View struct {
	Zone      string
	Host      string
	Version   string
	Projects  []ProjectRow
	Services  []ServiceRow
	Databases []DatabaseRow
	Infra     []InfraRow
}

// ProjectRow shows one project. Status is the lifecycle word from
// state.Project.Status; Running colours the badge.
type ProjectRow struct {
	Name    string
	Status  string
	Running bool
	Type    string
	URL     string
	// Database connection details, derived from the project name;
	// see docs/security.md.
	DBHost string
	DBUser string
	DBPass string
	// Links are per-project links from running extra services,
	// populated only when the pieces each link needs are up.
	Links []service.Link
}

// InfraRow is one VM-integral infrastructure piece (
// dnsmasq, portal) as the page shows it.
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

// ServiceRow is one extra service as the page shows it.
type ServiceRow struct {
	Name    string
	Status  string
	Running bool
	IP      string
	DNS     string
	Access  string
}

// pageData assembles the view from mpd's own typed state. Container
// states come from a few `podman ps` calls, not an inspect per item:
// per-item calls race a restart mid-render.
func pageData(ctx context.Context, d Deps) View {
	host, _ := os.Hostname()
	v := View{Zone: d.Net.Zone(), Host: host, Version: d.Version}
	projects := d.State.Projects()

	// Gathered once and shared, so rows cannot disagree.
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

// projectLinks collects what every running extra service offers for one
// project, gated on the project's database being up.
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

// infraRows lists the VM-integral infrastructure: the systemd units on
// the VM.
func infraRows(ctx context.Context, d Deps) []InfraRow {
	var rows []InfraRow
	for _, inf := range vm.InfraServices() {
		row := InfraRow{Name: inf.Name, Status: "stopped"}
		switch inf.Name {
		case "dnsmasq":
			row.Access = fmt.Sprintf("DNS resolver (%s:53)", d.Net.Gateway())
		case "portal":
			row.Access = fmt.Sprintf("https://%s/", d.Net.Zone())
		case "projects":
			row.Access = fmt.Sprintf("project HTTPS (%s:443)", d.Net.IP(net.HostProjects))
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

// serviceRows lists the extra services, joining recorded presence
// against what podman has.
func serviceRows(ctx context.Context, d Deps, live map[string]string) []ServiceRow {
	installed := map[string]bool{}
	for _, entry := range d.State.Services() {
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
		case installed[svc.Name]:
			row.Status = "stopped"
		}
		if !installed[svc.Name] {
			row.Access = "mpd --service-start=" + svc.Name
		}
		rows = append(rows, row)
	}
	return rows
}

// podmanServiceFilter mirrors cli.serviceFilter; duplicated so the page
// does not import the CLI layer.
const podmanServiceFilter = "label=com.docker.compose.project=mpd-service"

func label(item podman.PsItem, key, fallback string) string {
	if v := item.Label(key); v != "" {
		return v
	}
	return fallback
}

// dbHost is the DB container's name in this VM's zone; empty when the
// project has no database yet.
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
