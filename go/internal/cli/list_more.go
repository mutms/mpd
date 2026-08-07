package cli

import (
	"context"
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/current"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/runtime"
	"github.com/mutms/mpd/go/internal/state"
)

// Column widths for the runtime and DB tables.
const (
	colRuntimeName = 18
	colRequested   = 12
	colCurrent     = 10
	colDNS         = 28
	colDatabase    = 16
	colDBStatus    = 10
)

// ListRuntimes renders `list runtimes` — a single row now that there is
// exactly one runtime per VM. It still renders when the container is
// missing ("missing" with no address), pointing at `mpd --vm-setup`.
func ListRuntimes(ctx context.Context, out io.Writer, n net.Net, p *podman.Client, s state.Store, a assets.Tree) {
	ip, dns := "—", "—"
	requested, current := "-", "missing (run mpd --vm-setup)"

	// Filter on the *presence* of mpd.runtime, not on a type label:
	// the runtime container carries mpd.runtime=runtime, and there is
	// no mpd.type=runtime label.
	for _, item := range p.Ps(ctx, "label=mpd.runtime") {
		if item.Label("mpd.name") != runtime.Name {
			continue
		}
		ip = item.Label("mpd.ip")
		if ip == "" {
			ip = p.ContainerIP(ctx, item.Name(), "mpd-internal")
		}
		dns = n.RuntimeFQDN()
		// Persisted intent drives reconciliation; live observation
		// drives the display of what actually is.
		if entry, ok := s.Runtime(runtime.Name); ok && entry.Requested != "" {
			requested = entry.Requested
		}
		if item.State == "running" {
			current = StatusRunning
		} else {
			current = StatusStopped
		}
	}

	fmt.Fprintln(out, Col("NAME", colRuntimeName)+Col("REQUESTED", colRequested)+
		Col("STATUS", colCurrent)+Col("IP", colIP)+Col("DNS", colDNS)+"PROJECTS")
	fmt.Fprintln(out, Rule(100))

	count := len(s.Projects())
	label := fmt.Sprintf("%d project%s", count, plural(count))
	fmt.Fprintln(out, Col(runtime.Name, colRuntimeName)+
		StatusLabel(requested, colRequested)+
		StatusLabel(current, colCurrent)+
		Col(ip, colIP)+Col(dns, colDNS)+label)
}

// ListDatabases renders `list dbs`.
//
// Rows come from live containers rather than databases.json: the cache
// records what mpd created, the containers are what exists. Labels carry
// engine and version so a container adopted from an older scheme still
// renders.
func ListDatabases(ctx context.Context, out io.Writer, n net.Net, p *podman.Client, s state.Store) {
	items := p.Ps(ctx, "label=mpd.type=db")
	if len(items) == 0 {
		fmt.Fprintln(out, "No DB containers found.")
		return
	}

	byDB := state.ProjectNamesByDatabase(s.Projects())

	type row struct{ database, status, dns, projects string }
	rows := make([]row, 0, len(items))
	for _, item := range items {
		engine := labelOr(item, "mpd.db.engine", "-")
		version := labelOr(item, "mpd.db.version", "-")
		databaseID := item.Label("mpd.name")
		if databaseID == "" {
			databaseID = engine + "-" + strings.ReplaceAll(version, ".", "-")
		}
		status := StatusStopped
		if item.State == "running" {
			status = StatusRunning
		}
		projects := "-"
		if names, ok := byDB[databaseID]; ok {
			projects = strings.Join(names, ", ")
		}
		rows = append(rows, row{
			database: engine + ":" + version,
			status:   status,
			dns:      n.DB(databaseID),
			projects: projects,
		})
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].database < rows[j].database })

	fmt.Fprintln(out, Col("DATABASE", colDatabase)+Col("STATUS", colDBStatus)+
		Col("DNS", colDNS)+"PROJECTS")
	fmt.Fprintln(out, Rule(84))
	for _, r := range rows {
		fmt.Fprintln(out, Col(r.database, colDatabase)+
			StatusLabel(r.status, colDBStatus)+
			Col(r.dns, colDNS)+r.projects)
	}
}

// ListProjects renders `list projects`.
//
// The REQUESTED and STATUS columns are different things and must be
// computed differently: requested is persisted intent, status is a live
// observation via internal/current. Rendering requested twice looks
// plausible and hides exactly the divergence the table exists to show.
func ListProjects(ctx context.Context, out io.Writer, s state.Store, o current.Observer) {
	projects := s.Projects()
	if len(projects) == 0 {
		fmt.Fprintln(out, "No projects found.")
		return
	}

	fmt.Fprintln(out, Col("PROJECT", colService)+Col("REQUESTED", colRequested)+
		Col("STATUS", colCurrent)+Col("TYPE", colCurrent)+
		Col("RUNTIME", colCurrent)+Col("DB", colDatabase)+"URL")
	fmt.Fprintln(out, Rule(100))

	for _, p := range projects {
		db := p.DatabaseID
		if db == "" {
			db = "-"
		}
		rt := p.RuntimeName
		if rt == "" {
			rt = "—"
		}
		fmt.Fprintln(out, Col(p.Name, colService)+
			StatusLabel(p.Requested, colRequested)+
			StatusLabel(string(o.Project(ctx, p)), colCurrent)+
			Col(p.Type, colCurrent)+Col(rt, colCurrent)+
			Col(db, colDatabase)+p.MainURL())
	}
}

func labelOr(item podman.PsItem, key, fallback string) string {
	if v := item.Label(key); v != "" {
		return v
	}
	return fallback
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}
