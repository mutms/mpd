package cli

import (
	"context"
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/mutms/mpd/go/internal/current"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
)

// showLabelWidth is the left column of the key/value show output.
const showLabelWidth = 16

// ShowProject renders `mpd status <project>`.
//
// Two shapes, not one: a project whose runtime is up AND that was asked
// to run gets the full detail (URLs, SSH, resolved settings); anything
// else gets the short form plus the single next command to type. The
// long form would be misleading otherwise — it lists URLs that nothing
// is serving.
func ShowProject(ctx context.Context, out io.Writer, name string, s state.Store,
	p *podman.Client, o current.Observer, n net.Net, uid string) {

	var entry state.Project
	found := false
	for _, candidate := range s.Projects() {
		if candidate.Name == name {
			entry, found = candidate, true
			break
		}
	}
	if !found {
		fmt.Fprintf(out, "Project '%s' not found. Create it: mpd %s create\n", name, name)
		return
	}

	typeStr := entry.Type
	if typeStr == "" {
		typeStr = "(not detected)"
	}
	fmt.Fprintln(out, field("Project:", name))
	fmt.Fprintln(out, field("Type:", typeStr))
	if cfg := configurationDisplay(entry); cfg != "" {
		fmt.Fprintln(out, field("Configuration:", cfg))
	}
	fmt.Fprintln(out, field("Requested:", entry.Requested))
	fmt.Fprintln(out, field("Current:", string(o.Project(ctx, entry))))

	if entry.RuntimeName == "" {
		fmt.Fprintf(out, "%s\n\n  mpd %s create\n", field("Runtime:", "—"), name)
		return
	}

	rt := entry.RuntimeName
	rtRunning := p.Running(ctx, o.RuntimeContainer(rt))

	if entry.Requested == "running" && rtRunning {
		fmt.Fprintln(out, field("Runtime:", rt))
		writeURLs(out, entry.URLs)
		fmt.Fprintln(out, field("SSH:", "ssh "+n.RuntimeAlias()))
		fmt.Fprintln(out, field("Directory:", "/srv/projects/"+name))
		writeSettings(out, name)
		return
	}

	live := "stopped"
	if rtRunning {
		live = "running"
	}
	fmt.Fprintln(out, field("Runtime:", fmt.Sprintf("%s  (last used — %s)", rt, live)))
	fmt.Fprintln(out, field("Directory:", "/srv/projects/"+name))
	fmt.Fprintf(out, "\n  mpd %s start\n", name)
}

// writeURLs prints the URL block, label column padded to the widest
// label so the URLs line up.
func writeURLs(out io.Writer, urls []state.ProjectURL) {
	if len(urls) == 0 {
		return
	}
	width := 0
	for _, u := range urls {
		if len(u.Label) > width {
			width = len(u.Label)
		}
	}
	for i, u := range urls {
		prefix := strings.Repeat(" ", showLabelWidth)
		if i == 0 {
			prefix = pad("URLs:", showLabelWidth)
		}
		fmt.Fprintf(out, "%s%s%s  %s\n", prefix, u.Label,
			strings.Repeat(" ", width-len(u.Label)), u.URL)
	}
}

// writeSettings surfaces what the project type's configure.sh resolved,
// from /srv/meta/<project>/effective.json. mpd does not interpret these
// — it shows them so the four-layer env cascade is inspectable.
func writeSettings(out io.Writer, project string) {
	var eff map[string]any
	if !srv.ReadMetaJSON(project, "effective.json", &eff) || len(eff) == 0 {
		return
	}
	keys := make([]string, 0, len(eff))
	width := 0
	for k := range eff {
		keys = append(keys, k)
		if len(k) > width {
			width = len(k)
		}
	}
	sort.Strings(keys)
	for i, k := range keys {
		prefix := strings.Repeat(" ", showLabelWidth)
		if i == 0 {
			prefix = pad("Settings:", showLabelWidth)
		}
		fmt.Fprintf(out, "%s%s%s  %v\n", prefix, k,
			strings.Repeat(" ", width-len(k)), eff[k])
	}
}

// configurationDisplay summarises the project's configured DB, if any.
func configurationDisplay(p state.Project) string {
	if p.DatabaseEngine == "" {
		return ""
	}
	return p.DatabaseEngine + ":" + p.DatabaseVersion
}

func field(label, value string) string     { return pad(label, showLabelWidth) + value }
func showField(label, value string) string { return pad(label, 12) + value }

func pad(s string, w int) string {
	if len(s) >= w {
		return s + " "
	}
	return s + strings.Repeat(" ", w-len(s))
}

func orDash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}
