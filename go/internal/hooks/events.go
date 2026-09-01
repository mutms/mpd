package hooks

import (
	"context"

	"github.com/mutms/mpd/go/internal/db"
	"github.com/mutms/mpd/go/internal/podman"
)

// The event catalogue, closed by design (docs/hooks.md). Names are a
// public contract: renaming one silently orphans every subscribing
// hook, because a directory matching no event is never scanned.
const (
	EventMpdPostSetup     = "mpd-post-setup"
	EventMpdPreStop       = "mpd-pre-stop"
	EventProjectPreStart  = "project-pre-start"
	EventProjectPreStop   = "project-pre-stop"
	EventProjectPostStart = "project-post-start"
)

// Project describes the project an event concerns.
type Project struct {
	Name string
	// DBEngine and DBVersion identify the project's database, if any.
	// Empty engine means database-audience events fire nowhere — normal.
	DBEngine, DBVersion string
}

func (pr Project) env() map[string]string {
	return map[string]string{
		"PROJECT":    pr.Name,
		"DB_ENGINE":  pr.DBEngine,
		"DB_VERSION": pr.DBVersion,
	}
}

// ProjectPreStart fires before a project starts: the database is up,
// but no project setup has run. It fires on the DATABASE, and failure
// aborts the start.
func ProjectPreStart(ctx context.Context, pr Project, p *podman.Client) Event {
	return projectEvent(ctx, EventProjectPreStart, pr, p,
		[]AudienceKind{AudienceDatabase}, Abort)
}

// ProjectPreStop fires while the project is still live. Failure never
// blocks a stop.
func ProjectPreStop(ctx context.Context, pr Project, p *podman.Client) Event {
	return projectEvent(ctx, EventProjectPreStop, pr, p,
		[]AudienceKind{AudienceVM}, Continue)
}

// ProjectPostStart fires once the project is live and recorded running.
func ProjectPostStart(ctx context.Context, pr Project, p *podman.Client) Event {
	return projectEvent(ctx, EventProjectPostStart, pr, p,
		[]AudienceKind{AudienceVM}, Continue)
}

// MpdPostSetup fires at the end of `mpd --vm-setup`. Failure never
// aborts: setup is already done.
func MpdPostSetup(ctx context.Context, p *podman.Client) Event {
	return Event{
		Name:       EventMpdPostSetup,
		Revision:   1,
		Audiences:  []AudienceKind{AudienceVM},
		OnFailure:  Continue,
		Timeout:    SetupTimeout,
		Containers: func(AudienceKind) []string { return nil },
	}
}

// Only narrows an event to some of its audiences, for a caller that has
// already covered the rest.
func (ev Event) Only(audiences ...AudienceKind) Event {
	ev.Audiences = audiences
	return ev
}

// MpdPreStop fires before the VM stops, on every running database, so
// engines shut down cleanly rather than being killed with pending IO.
// Failure never blocks a stop.
func MpdPreStop(ctx context.Context, p *podman.Client) Event {
	return Event{
		Name:      EventMpdPreStop,
		Revision:  1,
		Audiences: []AudienceKind{AudienceDatabase},
		OnFailure: Continue,
		Timeout:   StopTimeout,
		Env:       map[string]string{},
		Containers: func(a AudienceKind) []string {
			if a != AudienceDatabase {
				return nil
			}
			var out []string
			for _, item := range p.Ps(ctx, "label=mpd.type=db") {
				if item.State == "running" && item.Name() != "" {
					out = append(out, item.Name())
				}
			}
			return out
		},
	}
}

func projectEvent(ctx context.Context, name string, pr Project, p *podman.Client,
	audiences []AudienceKind, onFailure FailureMode) Event {

	return Event{
		Name:      name,
		Revision:  1,
		Audiences: audiences,
		OnFailure: onFailure,
		Env:       pr.env(),
		Containers: func(a AudienceKind) []string {
			switch a {
			case AudienceDatabase:
				if pr.DBEngine == "" {
					return nil
				}
				return running(ctx, p, db.ContainerName(pr.DBEngine, pr.DBVersion))
			default:
				return nil
			}
		},
	}
}

// running filters to containers that are up: firing into a stopped
// container would report a failure for "not applicable".
func running(ctx context.Context, p *podman.Client, names ...string) []string {
	var out []string
	for _, n := range names {
		if n != "" && p.Running(ctx, n) {
			out = append(out, n)
		}
	}
	return out
}
