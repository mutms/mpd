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
// but before `mpd --start`, a project reads requested=running,
// current=stopped, which is what makes the pending reconciliation
// legible instead of mysterious. Never persist a value from here into a
// requested field. See docs/HOOKS.md §"Resource lifecycle model".
package current

import (
	"context"
	"fmt"

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

// NewObserver returns an Observer. vmID prefixes runtime container names
// (`mpd-<id>-<runtime>-main`).
func NewObserver(vmID string, p *podman.Client) Observer {
	return Observer{vmID: vmID, p: p}
}

// RuntimeContainer is the main container name for a runtime.
func (o Observer) RuntimeContainer(runtime string) string {
	return fmt.Sprintf("mpd-%s-%s-main", o.vmID, runtime)
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
