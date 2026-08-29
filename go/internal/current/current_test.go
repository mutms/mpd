package current

import (
	"context"
	"strings"
	"testing"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/state"
)

// fakePodman answers `container exists` and `inspect .State.Running`
// from a map of container name → running, treating absent names as
// non-existent.
func fakePodman(containers map[string]bool) *podman.Client {
	return podman.NewWith(func(ctx context.Context, args []string) (exec.Result, error) {
		joined := strings.Join(args, " ")
		var name string
		for _, a := range args {
			if strings.HasPrefix(a, "mpd-") {
				name = a
			}
		}
		running, exists := containers[name]
		switch {
		case strings.HasPrefix(joined, "container exists"):
			if exists {
				return exec.Result{Code: 0}, nil
			}
			return exec.Result{Code: 1}, nil
		case strings.Contains(joined, ".State.Running"):
			if running {
				return exec.Result{Code: 0, Stdout: "true"}, nil
			}
			return exec.Result{Code: 0, Stdout: "false"}, nil
		}
		return exec.Result{Code: 0}, nil
	})
}

func TestRuntimeContainerName(t *testing.T) {
	o := NewObserver("150", fakePodman(nil))
	if got := o.RuntimeContainer("runtime"); got != "mpd-150-runtime" {
		t.Errorf("RuntimeContainer() = %q", got)
	}
}

func TestRuntime(t *testing.T) {
	o := NewObserver("150", fakePodman(map[string]bool{
		"mpd-150-runtime": true,
		"mpd-150-other":   false,
	}))
	ctx := context.Background()
	for name, want := range map[string]State{"runtime": Running, "other": Stopped, "util": Missing} {
		if got := o.Runtime(ctx, name); got != want {
			t.Errorf("Runtime(%q) = %q, want %q", name, got, want)
		}
	}
}

// A project's state derives from its runtime joined with its intent:
// a running runtime only makes a project running when it was asked to run.
func TestProjectDerivation(t *testing.T) {
	o := NewObserver("150", fakePodman(map[string]bool{
		"mpd-150-runtime": true,  // running
		"mpd-150-other":   false, // stopped
	}))
	ctx := context.Background()

	tests := []struct {
		name    string
		project state.Project
		want    State
	}{
		{"no runtime assigned", state.Project{Autostart: true}, Missing},
		{"runtime container gone", state.Project{RuntimeName: "gone", Autostart: true}, Missing},
		{"runtime stopped", state.Project{RuntimeName: "other", Autostart: true}, Stopped},
		{"runtime running and autostart", state.Project{RuntimeName: "runtime", Autostart: true}, Running},
		{"runtime running but not autostart", state.Project{RuntimeName: "runtime", Autostart: false}, Stopped},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := o.Project(ctx, tc.project); got != tc.want {
				t.Errorf("Project() = %q, want %q", got, tc.want)
			}
		})
	}
}

// current must be an observation, not a copy of intent: a project with
// Autostart set but a stopped runtime is observed stopped, not running.
func TestCurrentIsObserved(t *testing.T) {
	o := NewObserver("150", fakePodman(map[string]bool{"mpd-150-runtime": false}))
	p := state.Project{RuntimeName: "runtime", Autostart: true}
	if got := o.Project(context.Background(), p); got != Stopped {
		t.Fatalf("Project() = %q, want stopped — current must be observed, not copied from Autostart", got)
	}
}

func TestDB(t *testing.T) {
	o := NewObserver("150", fakePodman(map[string]bool{
		"mpd-db-postgres-latest": true,
		"mpd-db-mariadb-11":      false,
	}))
	ctx := context.Background()
	for name, want := range map[string]State{
		"mpd-db-postgres-latest": Running,
		"mpd-db-mariadb-11":      Stopped,
		"mpd-db-mysql-9":         Missing,
	} {
		if got := o.DB(ctx, name); got != want {
			t.Errorf("DB(%q) = %q, want %q", name, got, want)
		}
	}
}
