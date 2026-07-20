package hooks

import (
	"os"
	"path/filepath"
	"testing"
)

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
		"runtimes/php/hooks/project-post-start.d/10-real.sh":    "#!/bin/bash\n",
		"runtimes/php/hooks/project-post-start.d/20-noext":      "#!/bin/bash\n",
		"runtimes/php/hooks/project-post-start.d/30-old.sh.bak": "#!/bin/bash\n",
		"runtimes/php/hooks/project-post-start.d/40-vim.sh~":    "#!/bin/bash\n",
		"runtimes/php/hooks/project-post-start.d/README.md":     "# docs\n",
	})
	ev := Event{Name: EventProjectPostStart, Runtime: "php"}
	got := discover(ev, AudienceRuntime)
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
		"runtimes/php/hooks/project-post-start.d/90-last.sh":  "",
		"runtimes/php/hooks/project-post-start.d/10-first.sh": "",
		"runtimes/php/hooks/project-post-start.d/50-mid.sh":   "",
	})
	got := discover(Event{Name: EventProjectPostStart, Runtime: "php"}, AudienceRuntime)
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

// Layer order is base → runtime → type, so a broadly-applicable hook
// runs before a more specific one.
func TestLayerOrder(t *testing.T) {
	withAssets(t, map[string]string{
		"runtime-base/hooks/project-post-start.d/10-base.sh":                      "",
		"runtimes/php/hooks/project-post-start.d/10-runtime.sh":                   "",
		"runtimes/php/project_types/moodle/hooks/project-post-start.d/10-type.sh": "",
	})
	ev := Event{
		Name: EventProjectPostStart, Runtime: "php",
		ProjectType: "moodle", ProjectTypeRuntime: "php",
	}
	got := discover(ev, AudienceRuntime)
	want := []string{"10-base.sh", "10-runtime.sh", "10-type.sh"}
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
		"runtimes/php/hooks/project-pre-start.d/10-runtime.sh":  "",
		"databases/postgres/hooks/project-pre-start.d/10-db.sh": "",
	})
	ev := Event{Name: EventProjectPreStart, Runtime: "php", DBEngine: "postgres"}

	rt := discover(ev, AudienceRuntime)
	if len(rt) != 1 || rt[0].Basename != "10-runtime.sh" {
		t.Errorf("runtime audience = %+v", rt)
	}
	dbs := discover(ev, AudienceDatabase)
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
	got := discover(Event{Name: EventProjectPreStart}, AudienceDatabase)
	if len(got) != 0 {
		t.Errorf("got %d scripts with no engine, want 0", len(got))
	}
}

func TestMissingDirectoryIsNotAnError(t *testing.T) {
	withAssets(t, map[string]string{})
	if got := discover(Event{Name: EventProjectPostStart, Runtime: "php"}, AudienceRuntime); len(got) != 0 {
		t.Errorf("got %d scripts, want 0", len(got))
	}
}

// The container path must be the same absolute path, because /opt/mpd is
// bind-mounted read-only at the same location inside every container —
// that is what lets a host-side scan produce an executable path.
func TestContainerPathMatchesHostPath(t *testing.T) {
	dir := withAssets(t, map[string]string{
		"runtimes/php/hooks/project-post-start.d/10-x.sh": "",
	})
	got := discover(Event{Name: EventProjectPostStart, Runtime: "php"}, AudienceRuntime)
	if len(got) != 1 {
		t.Fatalf("got %d scripts", len(got))
	}
	want := filepath.Join(dir, "runtimes/php/hooks/project-post-start.d/10-x.sh")
	if got[0].ContainerPath != want {
		t.Errorf("ContainerPath = %q, want %q", got[0].ContainerPath, want)
	}
}
