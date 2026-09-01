package cli

import (
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
)

// showLabelWidth is the left column of the key/value show output.
const showLabelWidth = 16

// ShowProject renders `mpd status <project>`. A started project gets the
// full detail; a stopped or uninitialised one gets the short form plus
// the next command — the long form would list URLs nothing serves. The
// project frontdoor is the same for every project, so it is not shown.
func ShowProject(out io.Writer, name string, s state.Store, n net.Net) {
	var entry state.Project
	found := false
	for _, candidate := range s.Projects() {
		if candidate.Name == name {
			entry, found = candidate, true
			break
		}
	}
	if !found {
		fmt.Fprintf(out, "Project '%s' not found. Create it: mpd init %s\n", name, name)
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
	fmt.Fprintln(out, field("Status:", entry.Status()))

	// Not initialised: no addresses to show yet, just the command to run.
	if !entry.Configured {
		fmt.Fprintf(out, "\n  mpd start %s\n", name)
		return
	}

	if entry.Autostart {
		writeURLs(out, entry.URLs)
		fmt.Fprintln(out, field("Directory:", "/srv/projects/"+name))
		writeSettings(out, name)
		return
	}

	// Stopped: lead with how to bring it back, not URLs that answer with
	// a dead page.
	fmt.Fprintln(out, field("Directory:", "/srv/projects/"+name))
	fmt.Fprintf(out, "\n  mpd start %s\n", name)
}

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

// writeSettings shows what the type's configure.sh resolved; mpd does
// not interpret the values.
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
