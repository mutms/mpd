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
	"github.com/mutms/mpd/go/internal/state"
)

// Column widths for the runtime and DB tables (mpd/Runtime/Runtime.swift
// and mpd/CLI/Status.swift).
const (
	colRuntimeName = 18
	colRequested   = 12
	colCurrent     = 10
	colDNS         = 28
	colDatabase    = 16
	colDBStatus    = 10
)

// ListRuntimes renders `list runtimes`.
//
// The table unions two sources: runtimes that exist as containers, and
// runtimes the asset tree says could be created. That is why a runtime
// mpd has never built still appears — as "available" with no address —
// rather than being invisible until first use.
func ListRuntimes(ctx context.Context, out io.Writer, n net.Net, p *podman.Client, s state.Store, a assets.Tree) {
	created := map[string]podman.PsItem{}
	// Filter on the *presence* of mpd.runtime, not on a type label:
	// runtime containers carry mpd.runtime=<name>, and there is no
	// mpd.type=runtime label. Matching a value here silently finds
	// nothing and every runtime renders as "available".
	for _, item := range p.Ps(ctx, "label=mpd.runtime") {
		name := item.Label("mpd.name")
		if name == "" {
			name = item.Name()
		}
		if name != "" {
			created[name] = item
		}
	}

	nameSet := map[string]bool{}
	for name := range created {
		nameSet[name] = true
	}
	for _, name := range a.RuntimeNames() {
		nameSet[name] = true
	}
	if len(nameSet) == 0 {
		fmt.Fprintln(out, "No runtimes found.")
		return
	}
	names := make([]string, 0, len(nameSet))
	for name := range nameSet {
		names = append(names, name)
	}
	sort.Strings(names)

	projectCounts := state.ProjectsByRuntime(s.Projects())

	fmt.Fprintln(out, Col("NAME", colRuntimeName)+Col("REQUESTED", colRequested)+
		Col("CURRENT", colCurrent)+Col("IP", colIP)+Col("DNS", colDNS)+"PROJECTS")
	fmt.Fprintln(out, Rule(100))

	for _, name := range names {
		ip, dns := "—", "—"
		requested, current := "-", "available"

		if item, ok := created[name]; ok {
			ip = item.Label("mpd.ip")
			if ip == "" {
				ip = p.ContainerIP(ctx, item.Name(), "mpd-internal")
			}
			dns = n.Runtime(name)
			// Persisted intent drives reconciliation; live observation
			// drives the display of what actually is.
			if entry, ok := s.Runtime(name); ok && entry.Requested != "" {
				requested = entry.Requested
			}
			if item.State == "running" {
				current = StatusRunning
			} else {
				current = StatusStopped
			}
		}

		count := projectCounts[name]
		label := fmt.Sprintf("%d project%s", count, plural(count))
		fmt.Fprintln(out, Col(name, colRuntimeName)+
			StatusLabel(requested, colRequested)+
			StatusLabel(current, colCurrent)+
			Col(ip, colIP)+Col(dns, colDNS)+label)
	}
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
// The REQUESTED and CURRENT columns are different things and must be
// computed differently: requested is persisted intent, current is a live
// observation via internal/current. Rendering requested twice looks
// plausible and hides exactly the divergence the table exists to show.
func ListProjects(ctx context.Context, out io.Writer, s state.Store, o current.Observer) {
	projects := s.Projects()
	if len(projects) == 0 {
		fmt.Fprintln(out, "No projects found.")
		return
	}

	fmt.Fprintln(out, Col("PROJECT", colService)+Col("REQUESTED", colRequested)+
		Col("CURRENT", colCurrent)+Col("TYPE", colCurrent)+
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
