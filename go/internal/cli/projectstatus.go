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

// ProjectStatus is what `mpd status <project> --json` prints: everything
// a script needs about a project in one document. Additive changes only
// — tools in the wild read fields by name.
type ProjectStatus struct {
	Name       string             `json:"name"`
	Type       string             `json:"type"`
	Configured bool               `json:"configured"`
	Status     string             `json:"status"`
	Autostart  bool               `json:"autostart"`
	Directory  string             `json:"directory"`
	DataDir    string             `json:"dataDir"`
	Zone       string             `json:"zone"`
	Database   *DatabaseStatus    `json:"database,omitempty"`
	URLs       []state.ProjectURL `json:"urls,omitempty"`
	Settings   map[string]any     `json:"settings,omitempty"`
}

// DatabaseStatus is the project's database, including what a client
// needs to connect. Name, User and Host are derived here so no script
// builds "<id>.db.<zone>" itself.
type DatabaseStatus struct {
	ID      string `json:"id"`
	Engine  string `json:"engine"`
	Version string `json:"version"`
	Host    string `json:"host"`
	Name    string `json:"name"`
	User    string `json:"user"`
}

// ShowProjectJSON prints a project's status as JSON. A missing project
// is an error, not `{}` — a script would read that as "exists but
// unconfigured".
func ShowProjectJSON(ctx context.Context, out io.Writer, name string, s state.Store,
	p *podman.Client, o current.Observer, n net.Net) error {

	entry, found := findProject(s, name)
	if !found {
		return fmt.Errorf("Project '%s' not found.", name)
	}

	status := ProjectStatus{
		Name:      entry.Name,
		Type:      entry.Type,
		Status:    entry.Status(),
		Autostart: entry.Autostart,
		Directory: srv.ProjectDir(entry.Name),
		DataDir:   srv.DataDir(entry.Name),
		Zone:      n.Zone(),
		URLs:      entry.URLs,
	}

	// The presence of effective.json, written by the type's
	// configure.sh, is what "configured" means.
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
