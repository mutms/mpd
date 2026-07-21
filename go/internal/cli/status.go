package cli

import (
	"context"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/vm"
)

// Status prints a context-aware overview: every runtime, the projects
// inside it, and the two kinds of thing that need the developer's
// attention — projects whose runtime is gone, and project directories on
// the volume that mpd does not know about.
//
// Grouped by runtime rather than listed flat because that is the shape
// the developer works in: a runtime is the machine they SSH into, and a
// project only means something inside one.
func Status(ctx context.Context, out io.Writer, s state.Store, p *podman.Client, n net.Net, uid string) {
	if _, err := os.Stat(vm.VarLibDir); err != nil {
		fmt.Fprint(out, "mpd is not set up on this machine.\n\n"+
			"To get started:\n"+
			"  1. Build: make install\n"+
			"  2. Run: mpd --vm-setup\n")
		return
	}

	fmt.Fprint(out, "mpd  —  Moodle Plugin Development Environment\n\n")

	projects := s.Projects()
	byRuntime := map[string][]state.Project{}
	for _, pr := range projects {
		if pr.RuntimeName != "" {
			byRuntime[pr.RuntimeName] = append(byRuntime[pr.RuntimeName], pr)
		}
	}

	containers := p.Ps(ctx, "label=mpd.runtime")
	live := map[string]bool{}
	var names []string
	for _, item := range containers {
		name := item.Label("mpd.name")
		if name == "" {
			continue
		}
		names = append(names, name)
		live[name] = item.State == "running"
	}
	sort.Strings(names)

	for _, name := range names {
		status := "stopped"
		if live[name] {
			status = "running"
		}
		fmt.Fprintf(out, "\n%s  %s  ssh %s\n", name, status, n.Runtime(name))

		group := byRuntime[name]
		sort.Slice(group, func(i, j int) bool { return group[i].Name < group[j].Name })
		for _, pr := range group {
			url := ""
			if pr.Requested == "running" {
				url = "   https://" + n.Host(pr.Name) + "/"
			}
			fmt.Fprintf(out, "  %s   %s%s\n", pr.Name, pr.Requested, url)
		}
	}

	existing := map[string]bool{}
	for _, name := range names {
		existing[name] = true
	}
	var orphaned []state.Project
	for _, pr := range projects {
		if pr.RuntimeName == "" || !existing[pr.RuntimeName] {
			orphaned = append(orphaned, pr)
		}
	}
	if len(orphaned) > 0 {
		fmt.Fprintln(out, "\nOrphaned projects without runtime:")
		sort.Slice(orphaned, func(i, j int) bool { return orphaned[i].Name < orphaned[j].Name })
		for _, pr := range orphaned {
			fmt.Fprintf(out, "  %s%s→ mpd %s start\n",
				Col(pr.Name, 16), Col(pr.Requested, 16), pr.Name)
		}
	}

	known := map[string]bool{}
	for _, pr := range projects {
		known[pr.Name] = true
	}
	if unregistered := UnregisteredProjectDirs(known); len(unregistered) > 0 {
		fmt.Fprintln(out, "\nUnregistered project directories:")
		for _, name := range unregistered {
			fmt.Fprintf(out, "  %s→ mpd %s create\n", Col(name, 24), name)
		}
	}

	fmt.Fprintln(out, "\n  mpd --help                full flag reference")
}

// UnregisteredProjectDirs lists directories under /srv/projects/ that no
// registered project claims.
//
// They are real work someone did — a clone that never got registered, or
// a project whose state entry was lost — so status names them and the
// command that adopts them rather than ignoring them.
func UnregisteredProjectDirs(known map[string]bool) []string {
	var out []string
	for _, line := range srv.ListProjects() {
		name := strings.TrimSpace(line)
		if name != "" && !known[name] {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}
