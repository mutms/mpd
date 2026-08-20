package cli

import (
	"context"
	"fmt"
	"io"
	"path/filepath"
	"sort"
	"strings"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
)

// Column widths for the project and DB tables.
const (
	colCurrent  = 10
	colBranch   = 20
	colDNS      = 28
	colDatabase = 16
	colDBStatus = 10
)

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
// One STATUS column, from state.Project.Status: the autostart intent
// ("started"/"stopped"), or "not initialised" for a project that has never
// been configured. There is no separate live-observation column — a start
// that does not fully come up records itself stopped, so the stored status
// is the honest one.
func ListProjects(out io.Writer, s state.Store) {
	projects := s.Projects()
	if len(projects) == 0 {
		fmt.Fprintln(out, "No projects found.")
		return
	}

	fmt.Fprintln(out, Col("PROJECT", colService)+Col("STATUS", colStatus)+
		Col("TYPE", colCurrent)+Col("BRANCH", colBranch)+
		Col("DB", colDatabase)+"URL")
	fmt.Fprintln(out, Rule(100))

	for _, p := range projects {
		db := p.DatabaseID
		if db == "" {
			db = "-"
		}
		fmt.Fprintln(out, Col(p.Name, colService)+
			StatusLabel(p.Status(), colStatus)+
			Col(p.Type, colCurrent)+Col(gitBranch(p.Name), colBranch)+
			Col(db, colDatabase)+p.MainURL())
	}
}

// gitBranch reads a project's checked-out branch straight from
// /srv/projects/<name>/.git/HEAD — no `git` subprocess, per the
// host-command rule. Returns the branch name, a short commit for a
// detached HEAD, or "-" when the tree is not a git checkout.
func gitBranch(name string) string {
	head, ok := srv.Read(filepath.Join(srv.ProjectDir(name), ".git", "HEAD"))
	if !ok {
		return "-"
	}
	head = strings.TrimSpace(head)
	if ref := strings.TrimPrefix(head, "ref: refs/heads/"); ref != head {
		return ref
	}
	// Detached HEAD: the file holds a bare commit hash. Only treat it as
	// one when it actually looks like a hash — a `.git` that is a gitdir
	// pointer file (worktrees, submodules) is neither a ref nor a hash.
	if isHex(head) && len(head) >= 7 {
		return head[:7]
	}
	return "-"
}

// isHex reports whether s is a non-empty string of hex digits.
func isHex(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') && (c < 'A' || c > 'F') {
			return false
		}
	}
	return true
}

func labelOr(item podman.PsItem, key, fallback string) string {
	if v := item.Label(key); v != "" {
		return v
	}
	return fallback
}
