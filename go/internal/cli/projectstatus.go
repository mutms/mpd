package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/current"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
)

// ProjectStatus is what `mpd status <project> --json` prints: everything a
// script needs to know about a project, in one document.
//
// It exists because the in-runtime tools need these answers and, before
// mpd could be called from inside a runtime, had no way to ask — so they
// read /srv/meta/<project>/*.json themselves and built values like the
// database host by hand. Every one of those was a copy of a layout mpd
// owns, in a language with no way to check it. Now that `mpd status`
// answers from either side, the files are mpd's business again.
//
// Additive changes only: a field may be added, but tools in the wild
// read this by name.
type ProjectStatus struct {
	Name       string             `json:"name"`
	Type       string             `json:"type"`
	Configured bool               `json:"configured"`
	Requested  string             `json:"requested"`
	Current    string             `json:"current"`
	Runtime    string             `json:"runtime"`
	Directory  string             `json:"directory"`
	DataDir    string             `json:"dataDir"`
	Zone       string             `json:"zone"`
	Database   *DatabaseStatus    `json:"database,omitempty"`
	URLs       []state.ProjectURL `json:"urls,omitempty"`
	Settings   map[string]any     `json:"settings,omitempty"`
}

// DatabaseStatus is the project's database, including the parts a client
// needs to connect.
//
// Name, User and Host are not stored anywhere — they are derived, and
// derived identically by db.CreateFor and by every tool that has ever
// wanted to reach a project's database. Handing them over is the point:
// a script that builds "<id>.db.<zone>" itself is a script that breaks
// when addressing changes.
type DatabaseStatus struct {
	ID      string `json:"id"`
	Engine  string `json:"engine"`
	Version string `json:"version"`
	Host    string `json:"host"`
	Name    string `json:"name"`
	User    string `json:"user"`
}

// ShowProjectJSON prints a project's status as JSON.
//
// A project that does not exist is an error rather than an empty
// document: a script testing `.configured` on `{}` would read "exists
// but unconfigured", which is a different thing and the wrong one to
// act on.
func ShowProjectJSON(ctx context.Context, out io.Writer, name string, s state.Store,
	p *podman.Client, o current.Observer, n net.Net) error {

	entry, found := findProject(s, name)
	if !found {
		return fmt.Errorf("Project '%s' not found.", name)
	}

	status := ProjectStatus{
		Name:      entry.Name,
		Type:      entry.Type,
		Requested: entry.Requested,
		Current:   string(o.Project(ctx, entry)),
		Runtime:   entry.RuntimeName,
		Directory: srv.ProjectDir(entry.Name),
		DataDir:   srv.DataDir(entry.Name),
		Zone:      n.Zone(),
		URLs:      entry.URLs,
	}

	// effective.json is the project type's own output, written by its
	// configure.sh. Its presence is what "configured" means: mpd has run
	// the type's configure and the type has answered.
	var eff map[string]any
	if srv.ReadMetaJSON(entry.Name, "effective.json", &eff) && len(eff) > 0 {
		status.Configured = true
		status.Settings = eff
	}

	if entry.DatabaseEngine != "" {
		status.Database = &DatabaseStatus{
			ID:      entry.DatabaseID,
			Engine:  entry.DatabaseEngine,
			Version: entry.DatabaseVersion,
			Host:    entry.DatabaseID + ".db." + n.Zone(),
			Name:    entry.Name,
			User:    entry.Name,
		}
	}

	enc := json.NewEncoder(out)
	enc.SetIndent("", "  ")
	return enc.Encode(status)
}
