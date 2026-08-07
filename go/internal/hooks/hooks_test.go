package hooks

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/podman"
)

// labelled returns a podman stub whose containers report fixed labels,
// so discovery — which reads labels rather than event fields — can be
// exercised without a container engine.
func labelled(labels map[string]string) *podman.Client {
	return podman.NewWith(func(ctx context.Context, args []string) (exec.Result, error) {
		for key, value := range labels {
			for _, a := range args {
				if a == "{{index .Config.Labels \""+key+"\"}}" {
					return exec.Result{Code: 0, Stdout: value}, nil
				}
			}
		}
		return exec.Result{Code: 0}, nil
	})
}

func find(ev Event, audience AudienceKind, labels map[string]string) []Script {
	return discover(context.Background(), labelled(labels), ev, audience, "c")
}

// withAssets points AssetsDir at a fixture tree for the duration of a
// test, so discovery can be exercised without the real /opt/mpd.
func withAssets(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for rel, body := range files {
		path := filepath.Join(dir, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	old := assetsDir
	assetsDir = dir
	t.Cleanup(func() { assetsDir = old })
	return dir
}

// The whole point of the extension filter: anything that is not *.sh
// would otherwise be handed to bash and executed.
func TestOnlyShFilesAreDiscovered(t *testing.T) {
	withAssets(t, map[string]string{
		"runtime/hooks/project-post-start.d/10-real.sh":    "#!/bin/bash\n",
		"runtime/hooks/project-post-start.d/20-noext":      "#!/bin/bash\n",
		"runtime/hooks/project-post-start.d/30-old.sh.bak": "#!/bin/bash\n",
		"runtime/hooks/project-post-start.d/40-vim.sh~":    "#!/bin/bash\n",
		"runtime/hooks/project-post-start.d/README.md":     "# docs\n",
	})
	got := find(Event{Name: EventProjectPostStart}, AudienceRuntime, map[string]string{"mpd.name": "php"})
	if len(got) != 1 {
		names := []string{}
		for _, s := range got {
			names = append(names, s.Basename)
		}
		t.Fatalf("discovered %v, want only 10-real.sh", names)
	}
	if got[0].Basename != "10-real.sh" {
		t.Errorf("basename = %q", got[0].Basename)
	}
}

// Numeric prefixes are how hook authors order work; alphabetical sort
// within a layer is what makes them mean anything.
func TestScriptsAreOrderedWithinALayer(t *testing.T) {
	withAssets(t, map[string]string{
		"runtime/hooks/project-post-start.d/90-last.sh":  "",
		"runtime/hooks/project-post-start.d/10-first.sh": "",
		"runtime/hooks/project-post-start.d/50-mid.sh":   "",
	})
	got := find(Event{Name: EventProjectPostStart}, AudienceRuntime, map[string]string{"mpd.name": "php"})
	want := []string{"10-first.sh", "50-mid.sh", "90-last.sh"}
	if len(got) != len(want) {
		t.Fatalf("got %d scripts, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i].Basename != want[i] {
			t.Errorf("script[%d] = %q, want %q", i, got[i].Basename, want[i])
		}
	}
}

// Layer order is base → runtime, so a broadly-applicable hook runs
// before a more specific one.
//
// There is deliberately NO project-type layer for runtime-audience
// events: the Go implementation does not scan it, and firing hooks it
// never fired would be a silent behaviour change. The type directory
// below exists precisely to prove it is ignored.
func TestLayerOrderExcludesProjectType(t *testing.T) {
	withAssets(t, map[string]string{
		"runtime-base/hooks/project-post-start.d/10-base.sh":                 "",
		"runtime/hooks/project-post-start.d/10-runtime.sh":                   "",
		"runtime/project_types/moodle/hooks/project-post-start.d/10-type.sh": "",
	})
	got := find(Event{Name: EventProjectPostStart}, AudienceRuntime, map[string]string{"mpd.name": "php"})
	want := []string{"10-base.sh", "10-runtime.sh"}
	if len(got) != len(want) {
		t.Fatalf("got %d scripts, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i].Basename != want[i] {
			t.Errorf("script[%d] = %q, want %q", i, got[i].Basename, want[i])
		}
	}
}

// Audiences are per-event and not interchangeable: a database-audience
// event must not pick up runtime hooks, or a project-pre-start hook
// would run in the wrong container.
func TestAudienceSelectsDifferentAssetTrees(t *testing.T) {
	withAssets(t, map[string]string{
		"runtime/hooks/project-pre-start.d/10-runtime.sh":       "",
		"databases/postgres/hooks/project-pre-start.d/10-db.sh": "",
	})
	ev := Event{Name: EventProjectPreStart}
	labels := map[string]string{"mpd.name": "php", "mpd.db.engine": "postgres"}

	rt := find(ev, AudienceRuntime, labels)
	if len(rt) != 1 || rt[0].Basename != "10-runtime.sh" {
		t.Errorf("runtime audience = %+v", rt)
	}
	dbs := find(ev, AudienceDatabase, labels)
	if len(dbs) != 1 || dbs[0].Basename != "10-db.sh" {
		t.Errorf("database audience = %+v", dbs)
	}
}

// A project with no database has nothing to fire a database-audience
// event into. That is normal, not an error.
func TestNoEngineMeansNoDatabaseHooks(t *testing.T) {
	withAssets(t, map[string]string{
		"databases/postgres/hooks/project-pre-start.d/10-db.sh": "",
	})
	got := find(Event{Name: EventProjectPreStart}, AudienceDatabase, nil)
	if len(got) != 0 {
		t.Errorf("got %d scripts with no engine label, want 0", len(got))
	}
}

func TestMissingDirectoryIsNotAnError(t *testing.T) {
	withAssets(t, map[string]string{})
	if got := find(Event{Name: EventProjectPostStart}, AudienceRuntime, map[string]string{"mpd.name": "php"}); len(got) != 0 {
		t.Errorf("got %d scripts, want 0", len(got))
	}
}

// The container path must be the same absolute path, because /opt/mpd is
// bind-mounted read-only at the same location inside every container —
// that is what lets a host-side scan produce an executable path.
func TestContainerPathMatchesHostPath(t *testing.T) {
	dir := withAssets(t, map[string]string{
		"runtime/hooks/project-post-start.d/10-x.sh": "",
	})
	got := find(Event{Name: EventProjectPostStart}, AudienceRuntime, map[string]string{"mpd.name": "php"})
	if len(got) != 1 {
		t.Fatalf("got %d scripts", len(got))
	}
	want := filepath.Join(dir, "runtime/hooks/project-post-start.d/10-x.sh")
	if got[0].ContainerPath != want {
		t.Errorf("ContainerPath = %q, want %q", got[0].ContainerPath, want)
	}
}

// mpd-pre-stop fires on every running database at once, and those can be
// different engines. Discovery must therefore follow each CONTAINER, not
// a single value carried on the event — otherwise postgres's hooks get
// run inside mariadb.
func TestDiscoveryFollowsTheContainerNotTheEvent(t *testing.T) {
	withAssets(t, map[string]string{
		"databases/postgres/hooks/mpd-pre-stop.d/90-graceful-stop.sh": "",
		"databases/mariadb/hooks/mpd-pre-stop.d/90-graceful-stop.sh":  "",
		"databases/mariadb/hooks/mpd-pre-stop.d/50-mariadb-only.sh":   "",
	})
	ev := Event{Name: EventMpdPreStop}

	pg := find(ev, AudienceDatabase, map[string]string{"mpd.db.engine": "postgres"})
	if len(pg) != 1 || pg[0].Basename != "90-graceful-stop.sh" {
		t.Fatalf("postgres container discovered %+v", pg)
	}
	if !strings.Contains(pg[0].ContainerPath, "/databases/postgres/") {
		t.Errorf("postgres container got %q — wrong engine's assets", pg[0].ContainerPath)
	}

	maria := find(ev, AudienceDatabase, map[string]string{"mpd.db.engine": "mariadb"})
	if len(maria) != 2 {
		t.Fatalf("mariadb container discovered %+v", maria)
	}
	for _, s := range maria {
		if !strings.Contains(s.ContainerPath, "/databases/mariadb/") {
			t.Errorf("mariadb container got %q — wrong engine's assets", s.ContainerPath)
		}
	}
}

// The engine-shutdown hook must sort last: it SIGTERMs PID 1, so
// anything after it runs against a container already going down.
func TestGracefulStopSortsLast(t *testing.T) {
	withAssets(t, map[string]string{
		"databases/postgres/hooks/mpd-pre-stop.d/90-graceful-stop.sh": "",
		"databases/postgres/hooks/mpd-pre-stop.d/50-dump.sh":          "",
	})
	got := find(Event{Name: EventMpdPreStop}, AudienceDatabase,
		map[string]string{"mpd.db.engine": "postgres"})
	if len(got) != 2 || got[0].Basename != "50-dump.sh" || got[1].Basename != "90-graceful-stop.sh" {
		t.Fatalf("order = %+v, want the dump before the shutdown", got)
	}
}
