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
	"github.com/mutms/mpd/go/internal/runtime"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/vm"
)

// Status prints a context-aware overview: the projects, plus the two
// kinds of thing that need the developer's attention — a runtime that is
// not up, and project directories on the volume that mpd does not know
// about.
//
// The runtime is infrastructure, so it earns no line of its own when
// healthy — connection details are the host-side orchestrator's job.
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
	sort.Slice(projects, func(i, j int) bool { return projects[i].Name < projects[j].Name })
	if len(projects) == 0 {
		fmt.Fprintln(out, "  No projects yet — mpd create <name>")
	}
	for _, pr := range projects {
		// The project's own URL, not one composed from its name: a type
		// is free to publish something else in urls.json, and this line
		// should show what was actually published. Shown for a stopped
		// project too — configure published the vhost, cert and DNS, and
		// stop does not withdraw them.
		url := ""
		if u := pr.MainURL(); u != "" {
			url = "   " + u
		}
		fmt.Fprintf(out, "  %s   %s%s\n", pr.Name, pr.Requested, url)
	}

	runtimeExists, runtimeUp := false, false
	for _, item := range p.Ps(ctx, "label=mpd.runtime") {
		if item.Label("mpd.name") == runtime.Name {
			runtimeExists = true
			runtimeUp = item.State == "running"
		}
	}
	switch {
	case !runtimeExists:
		fmt.Fprintln(out, "\nThe runtime is missing — run: mpd --vm-setup")
	case !runtimeUp:
		fmt.Fprintln(out, "\nThe runtime is stopped — run: mpd --vm-start")
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
