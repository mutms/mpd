package hooks

import (
	"context"

	"github.com/mutms/mpd/go/internal/db"
	"github.com/mutms/mpd/go/internal/podman"
)

// The event catalogue. Closed by design: a hook author subscribes to
// what exists, and events are added only when a real use case drives one
// (docs/hooks.md §"Future trajectory").
//
// Names are the kebab-case form the `<name>.d` directories use, and they
// are a public contract: renaming one silently stops every subscribing
// hook, because a directory matching no event is simply never scanned.
const (
	EventMpdPostSetup     = "mpd-post-setup"
	EventMpdPreStop       = "mpd-pre-stop"
	EventProjectPreStart  = "project-pre-start"
	EventProjectPreStop   = "project-pre-stop"
	EventProjectPostStart = "project-post-start"
)

// TIMEOUTS are enforced: 30 s by default, 120 s for mpd-pre-stop, where
// a database flushing pending IO legitimately takes longer. See
// hooks.go for the caveat about what "killed" means for podman exec.

// Project describes the project an event concerns, and supplies
// everything both the environment and audience resolution need.
type Project struct {
	Name string
	// Runtime is the runtime's short name; RuntimeContainer is its
	// container. Both are needed: the name scopes asset discovery, the
	// container is what hooks execute in.
	Runtime          string
	RuntimeContainer string
	// DBEngine and DBVersion identify the project's database, if any.
	// Empty engine means the project has none, so database-audience
	// events fire nowhere — normal, not an error.
	DBEngine, DBVersion string
	// DevUser is who runtime hooks run as. See Event.User.
	DevUser string
}

func (pr Project) env() map[string]string {
	return map[string]string{
		"PROJECT":    pr.Name,
		"RUNTIME":    pr.Runtime,
		"DB_ENGINE":  pr.DBEngine,
		"DB_VERSION": pr.DBVersion,
	}
}

// ProjectPreStart fires before a project starts: runtime and database
// are up, but no project setup has run yet — the moment for per-project
// migrations or seed data.
//
// Audience is the project's DATABASE, not its runtime. Failure aborts
// the start: a project whose precondition failed should not come up
// half-configured.
func ProjectPreStart(ctx context.Context, pr Project, p *podman.Client) Event {
	return projectEvent(ctx, EventProjectPreStart, pr, p,
		[]AudienceKind{AudienceDatabase}, Abort)
}

// ProjectPreStop fires while the project is still live — draining work,
// flushing caches. Failure never blocks a stop.
func ProjectPreStop(ctx context.Context, pr Project, p *podman.Client) Event {
	return projectEvent(ctx, EventProjectPreStop, pr, p,
		[]AudienceKind{AudienceRuntime}, Continue)
}

// ProjectPostStart fires once the project is live and recorded running —
// cache warming, announcements, first-request triggers.
func ProjectPostStart(ctx context.Context, pr Project, p *podman.Client) Event {
	return projectEvent(ctx, EventProjectPostStart, pr, p,
		[]AudienceKind{AudienceRuntime}, Continue)
}

// MpdPostSetup fires at the end of `mpd --vm-setup`, once the VM and its
// runtime are fully configured. It is the point where "this VM is ready"
// becomes true, so a hook can install onto a VM that is finally able to
// hold the thing being installed.
//
// Audiences are the VM and its runtime, in that order — the same event on
// both sides of the boundary, because the developer's setup work lands on
// both (an IDE on the VM, an IDE backend in the runtime).
//
// Failure never aborts: setup has already done its work by the time this
// fires, and a developer's install script failing is not a reason to
// report the VM as unconfigured. The timeout is minutes, not seconds —
// see SetupTimeout.
func MpdPostSetup(ctx context.Context, runtimeContainer, devUser string, p *podman.Client) Event {
	return Event{
		Name:      EventMpdPostSetup,
		Revision:  1,
		Audiences: []AudienceKind{AudienceVM, AudienceRuntime},
		OnFailure: Continue,
		Timeout:   SetupTimeout,
		User:      devUser,
		Env:       map[string]string{"RUNTIME": runtimeContainer},
		Containers: func(a AudienceKind) []string {
			if a != AudienceRuntime {
				return nil
			}
			return running(ctx, p, runtimeContainer)
		},
	}
}

// Only narrows an event to a subset of its declared audiences, for a
// caller that has already covered the rest. mpd-post-setup uses it in
// both directions: a freshly created runtime is fired into by
// RuntimeCreate, so the `--vm-setup` that created it fires the VM side
// only, and each new runtime sees the event exactly once.
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
		User:      pr.DevUser,
		Env:       pr.env(),
		Containers: func(a AudienceKind) []string {
			switch a {
			case AudienceRuntime:
				return running(ctx, p, pr.RuntimeContainer)
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

// running filters to containers that are actually up: a hook cannot run
// in a stopped container, and firing into one would report a failure for
// something that is really "not applicable".
func running(ctx context.Context, p *podman.Client, names ...string) []string {
	var out []string
	for _, n := range names {
		if n != "" && p.Running(ctx, n) {
			out = append(out, n)
		}
	}
	return out
}
