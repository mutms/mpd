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

// Status prints the project overview plus what needs attention: a
// project frontdoor that is not up, and unregistered project
// directories. A healthy frontdoor gets no line of its own.
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
		fmt.Fprintln(out, "  No projects yet — mpd init <name>")
	}
	for _, pr := range projects {
		// Show the published URL, not one composed from the name. A
		// stopped project keeps its URL — stop does not withdraw it.
		url := ""
		if u := pr.MainURL(); u != "" {
			url = "   " + u
		}
		fmt.Fprintf(out, "  %s   %s%s\n", pr.Name, pr.Status(), url)
	}

	if !vm.UnitActive(ctx, vm.ProjectCaddyUnitName, false) {
		fmt.Fprintln(out, "\nThe project frontdoor is not running — run: mpd --vm-start")
	}

	known := map[string]bool{}
	for _, pr := range projects {
		known[pr.Name] = true
	}
	if unregistered := UnregisteredProjectDirs(known); len(unregistered) > 0 {
		fmt.Fprintln(out, "\nUnregistered project directories:")
		for _, name := range unregistered {
			fmt.Fprintf(out, "  %s→ mpd init %s\n", Col(name, 24), name)
		}
	}

	fmt.Fprintln(out, "\n  mpd --help                full flag reference")
}

// UnregisteredProjectDirs lists directories under /srv/projects/ that no
// registered project claims.
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
