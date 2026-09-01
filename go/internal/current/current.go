// Package current computes the live "current" state of
// projects and DB containers, as opposed to the persisted "requested"
// intent. Never persist a value from here into a requested field.
// See docs/hooks.md.
package current

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/state"
)

// State is a live observation. The zero value is invalid; use the
// constants.
type State string

const (
	// Running: the container exists and is running.
	Running State = "running"
	// Stopped: the container exists but is not running.
	Stopped State = "stopped"
	// Missing: the container does not exist — never created, or deleted.
	Missing State = "missing"
)

// Observer computes current state for a VM's containers.
type Observer struct {
	vmID string
	p    *podman.Client
}

// NewObserver returns an Observer.
func NewObserver(vmID string, p *podman.Client) Observer {
	return Observer{vmID: vmID, p: p}
}

// Project observes a project's effective state. A project has no
// container of its own, so this is its configured-ness joined with the
// Autostart intent.
func (o Observer) Project(ctx context.Context, p state.Project) State {
	switch {
	case !p.Configured:
		return Missing
	case p.Autostart:
		return Running
	default:
		return Stopped
	}
}

// DB observes a database container.
func (o Observer) DB(ctx context.Context, containerName string) State {
	if !o.p.Exists(ctx, containerName) {
		return Missing
	}
	if o.p.Running(ctx, containerName) {
		return Running
	}
	return Stopped
}

// Snapshot is the live-state view written to current-state.json, for
// consumers without podman access. Strictly observation — never mix it
// with the requested files.
type Snapshot struct {
	RefreshedAt string           `json:"refreshedAt"`
	Projects    map[string]State `json:"projects"`
	Databases   map[string]State `json:"databases"`
}

// Refresh recomputes the snapshot and writes it to stateDir. Every
// listing and lifecycle verb calls it, so readers see something recent.
func (o Observer) Refresh(ctx context.Context, stateDir string, s state.Store, now time.Time) error {
	snap := Snapshot{
		RefreshedAt: now.UTC().Format("2006-01-02T15:04:05Z"),
		Projects:    map[string]State{},
		Databases:   map[string]State{},
	}

	for _, p := range s.Projects() {
		snap.Projects[p.Name] = o.Project(ctx, p)
	}
	for _, item := range o.p.Ps(ctx, "label=mpd.type=db") {
		id := item.Label("mpd.name")
		if id == "" {
			continue
		}
		if item.State == "running" {
			snap.Databases[id] = Running
		} else {
			snap.Databases[id] = Stopped
		}
	}

	data, err := json.MarshalIndent(snap, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(stateDir, "current-state.json"), append(data, '\n'), 0o644)
}
