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

// A project has no container of its own, so its state is its
// configured-ness joined with the Autostart intent.
func TestProjectDerivation(t *testing.T) {
	o := NewObserver("150", fakePodman(nil))
	ctx := context.Background()

	tests := []struct {
		name    string
		project state.Project
		want    State
	}{
		{"never configured", state.Project{Autostart: true}, Missing},
		{"configured and started", state.Project{Configured: true, Autostart: true}, Running},
		{"configured and stopped", state.Project{Configured: true, Autostart: false}, Stopped},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := o.Project(ctx, tc.project); got != tc.want {
				t.Errorf("Project() = %q, want %q", got, tc.want)
			}
		})
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
