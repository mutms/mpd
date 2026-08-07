// Package current computes the live "current" state of runtimes,
// projects and DB containers.
//
// mpd keeps two things apart on purpose:
//
//   - **requested** — persisted intent, in projects.json and
//     runtimes/<n>/meta.json, changed only by explicit user verbs.
//   - **current** — live observation, computed from podman every time it
//     is needed and never persisted.
//
// Display layers join the two so divergence is visible: after a reboot
// but before `mpd --vm-start`, a project reads requested=running,
// current=stopped, which is what makes the pending reconciliation
// legible instead of mysterious. Never persist a value from here into a
// requested field. See docs/HOOKS.md §"Resource lifecycle model".
package current

import (
	"context"
	"encoding/json"
	"fmt"
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

// NewObserver returns an Observer. vmID prefixes the runtime container
// name (`mpd-<id>-<runtime>`).
func NewObserver(vmID string, p *podman.Client) Observer {
	return Observer{vmID: vmID, p: p}
}

// RuntimeContainer is the container name for a runtime.
func (o Observer) RuntimeContainer(runtime string) string {
	return fmt.Sprintf("mpd-%s-%s", o.vmID, runtime)
}

// Runtime observes a runtime's container.
func (o Observer) Runtime(ctx context.Context, name string) State {
	c := o.RuntimeContainer(name)
	if !o.p.Exists(ctx, c) {
		return Missing
	}
	if o.p.Running(ctx, c) {
		return Running
	}
	return Stopped
}

// Project observes a project's effective state.
//
// A project has no container of its own — its runtime hosts the
// processes — so its state is derived: no runtime, or a missing runtime
// container, means missing. A running runtime only makes the project
// running if the project was actually asked to run; otherwise it is
// stopped, because the runtime being up says nothing about this project.
func (o Observer) Project(ctx context.Context, p state.Project) State {
	if p.RuntimeName == "" {
		return Missing
	}
	switch o.Runtime(ctx, p.RuntimeName) {
	case Missing:
		return Missing
	case Stopped:
		return Stopped
	default:
		if p.Requested == "running" {
			return Running
		}
		return Stopped
	}
}

// DB observes a database container. DBs have no persisted intent — they
// are emergent from runtime and project records — so there is nothing to
// join against here.
func (o Observer) DB(ctx context.Context, containerName string) State {
	if !o.p.Exists(ctx, containerName) {
		return Missing
	}
	if o.p.Running(ctx, containerName) {
		return Running
	}
	return Stopped
}

// Snapshot is the live-state view written to current-state.json.
//
// Out-of-process consumers — the portal container, in-runtime tools —
// have no podman access and so cannot compute `current` themselves.
// This file is how they see it. It is strictly observation: never mixed
// with the `requested` files, which are strictly intent.
type Snapshot struct {
	RefreshedAt string           `json:"refreshedAt"`
	Runtimes    map[string]State `json:"runtimes"`
	Projects    map[string]State `json:"projects"`
	Databases   map[string]State `json:"databases"`
}

// Refresh recomputes the snapshot and writes it to stateDir.
//
// Called from every listing and lifecycle verb, so a consumer reading
// the file sees something recent without needing its own refresh path.
func (o Observer) Refresh(ctx context.Context, stateDir string, s state.Store, now time.Time) error {
	snap := Snapshot{
		RefreshedAt: now.UTC().Format("2006-01-02T15:04:05Z"),
		Runtimes:    map[string]State{},
		Projects:    map[string]State{},
		Databases:   map[string]State{},
	}

	entries, err := os.ReadDir(filepath.Join(stateDir, "runtimes"))
	if err == nil {
		for _, e := range entries {
			if e.IsDir() {
				snap.Runtimes[e.Name()] = o.Runtime(ctx, e.Name())
			}
		}
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
