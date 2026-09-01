package hooks

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/podman"
)

// labelled returns a podman stub whose containers report fixed labels.
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

// withAssets points assetsDir at a fixture tree for one test.
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

// Anything that is not *.sh would otherwise be handed to bash.
func TestOnlyShFilesAreDiscovered(t *testing.T) {
	withAssets(t, map[string]string{
		"vm/hooks/project-post-start.d/10-real.sh":    "#!/bin/bash\n",
		"vm/hooks/project-post-start.d/20-noext":      "#!/bin/bash\n",
		"vm/hooks/project-post-start.d/30-old.sh.bak": "#!/bin/bash\n",
		"vm/hooks/project-post-start.d/40-vim.sh~":    "#!/bin/bash\n",
		"vm/hooks/project-post-start.d/README.md":     "# docs\n",
	})
	got := find(Event{Name: EventProjectPostStart}, AudienceVM, map[string]string{"mpd.name": "php"})
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

// Alphabetical sort within a layer is what makes numeric prefixes
// mean anything.
func TestScriptsAreOrderedWithinALayer(t *testing.T) {
	withAssets(t, map[string]string{
		"vm/hooks/project-post-start.d/90-last.sh":  "",
		"vm/hooks/project-post-start.d/10-first.sh": "",
		"vm/hooks/project-post-start.d/50-mid.sh":   "",
	})
	got := find(Event{Name: EventProjectPostStart}, AudienceVM, map[string]string{"mpd.name": "php"})
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

// There is deliberately no project-type layer for VM-audience
// events; the type directory below exists to prove it is ignored.
func TestLayerOrderExcludesProjectType(t *testing.T) {
	withAssets(t, map[string]string{
		"vm/hooks/project-post-start.d/10-vm.sh":                        "",
		"vm/project_types/moodle/hooks/project-post-start.d/10-type.sh": "",
	})
	got := find(Event{Name: EventProjectPostStart}, AudienceVM, map[string]string{"mpd.name": "php"})
	want := []string{"10-vm.sh"}
	if len(got) != len(want) {
		t.Fatalf("got %d scripts, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i].Basename != want[i] {
			t.Errorf("script[%d] = %q, want %q", i, got[i].Basename, want[i])
		}
	}
}

// Audiences are per-event: a database-audience event must not pick up
// VM hooks.
func TestAudienceSelectsDifferentAssetTrees(t *testing.T) {
	withAssets(t, map[string]string{
		"vm/hooks/project-pre-start.d/10-vm.sh":                 "",
		"databases/postgres/hooks/project-pre-start.d/10-db.sh": "",
	})
	ev := Event{Name: EventProjectPreStart}
	labels := map[string]string{"mpd.name": "php", "mpd.db.engine": "postgres"}

	rt := find(ev, AudienceVM, labels)
	if len(rt) != 1 || rt[0].Basename != "10-vm.sh" {
		t.Errorf("vm audience = %+v", rt)
	}
	dbs := find(ev, AudienceDatabase, labels)
	if len(dbs) != 1 || dbs[0].Basename != "10-db.sh" {
		t.Errorf("database audience = %+v", dbs)
	}
}

// A project with no database fires database-audience events nowhere.
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
	if got := find(Event{Name: EventProjectPostStart}, AudienceVM, map[string]string{"mpd.name": "php"}); len(got) != 0 {
		t.Errorf("got %d scripts, want 0", len(got))
	}
}

// /opt/mpd is mounted at the same path inside every container, so a
// host-side scan must yield the identical executable path.
func TestContainerPathMatchesHostPath(t *testing.T) {
	dir := withAssets(t, map[string]string{
		"vm/hooks/project-post-start.d/10-x.sh": "",
	})
	got := find(Event{Name: EventProjectPostStart}, AudienceVM, map[string]string{"mpd.name": "php"})
	if len(got) != 1 {
		t.Fatalf("got %d scripts", len(got))
	}
	want := filepath.Join(dir, "vm/hooks/project-post-start.d/10-x.sh")
	if got[0].Path != want {
		t.Errorf("Path = %q, want %q", got[0].Path, want)
	}
}

// mpd-pre-stop fires on databases of different engines at once, so
// discovery must follow each container's own labels — otherwise one
// engine's hooks run inside another.
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
	if !strings.Contains(pg[0].Path, "/databases/postgres/") {
		t.Errorf("postgres container got %q — wrong engine's assets", pg[0].Path)
	}

	maria := find(ev, AudienceDatabase, map[string]string{"mpd.db.engine": "mariadb"})
	if len(maria) != 2 {
		t.Fatalf("mariadb container discovered %+v", maria)
	}
	for _, s := range maria {
		if !strings.Contains(s.Path, "/databases/mariadb/") {
			t.Errorf("mariadb container got %q — wrong engine's assets", s.Path)
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

// The VM audience reads the vm layer, and a database layer for the same
// event does not leak into it.
func TestVMAudienceReadsTheVMLayer(t *testing.T) {
	withAssets(t, map[string]string{
		"vm/hooks/mpd-post-setup.d/50-vm.sh":                 "",
		"databases/postgres/hooks/mpd-post-setup.d/50-db.sh": "",
	})
	ev := Event{Name: EventMpdPostSetup}

	got := find(ev, AudienceVM, nil)
	if len(got) != 1 || got[0].Basename != "50-vm.sh" {
		t.Errorf("vm audience = %+v, want just 50-vm.sh", got)
	}
}

// Whatever Containers says, the VM audience resolves to the fixed target.
func TestVMTargetIgnoresTheEventsContainers(t *testing.T) {
	ev := Event{
		Name:       EventMpdPostSetup,
		Containers: func(AudienceKind) []string { return []string{"wrong", "alsowrong"} },
	}
	got := ev.targets(AudienceVM)
	if len(got) != 1 || got[0] != VMTarget {
		t.Errorf("targets(AudienceVM) = %v, want [%s]", got, VMTarget)
	}
	if db := ev.targets(AudienceDatabase); len(db) != 2 {
		t.Errorf("targets(AudienceDatabase) = %v, want the event's own list", db)
	}
}

// End-to-end for the VM audience: the script really runs and sees the
// MPD_HOOK_* contract.
func TestVMHookRunsAndSeesItsEnvironment(t *testing.T) {
	out := filepath.Join(t.TempDir(), "seen")
	withAssets(t, map[string]string{
		"vm/hooks/mpd-post-setup.d/50-probe.sh": "printf '%s %s %s %s\\n' " +
			"\"$MPD_HOOK_EVENT\" \"$MPD_HOOK_REVISION\" \"$MPD_HOOK_VERB\" \"$MPD_HOOK_PROJECT\" > " + out + "\n",
	})
	ev := Event{
		Name: EventMpdPostSetup, Revision: 1,
		Audiences: []AudienceKind{AudienceVM},
		OnFailure: Continue,
		Env:       map[string]string{"PROJECT": "m45"},
	}
	if err := Fire(context.Background(), io.Discard, ev, "vm-setup", nil); err != nil {
		t.Fatalf("Fire: %v", err)
	}
	got, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("hook did not run: %v", err)
	}
	if want := "mpd-post-setup 1 vm-setup m45\n"; string(got) != want {
		t.Errorf("hook environment = %q, want %q", got, want)
	}
}

// A failing VM hook follows the same failure modes as a container one.
func TestVMHookFailureFollowsTheFailureMode(t *testing.T) {
	withAssets(t, map[string]string{
		"vm/hooks/mpd-post-setup.d/50-fail.sh": "exit 3\n",
	})
	base := Event{Name: EventMpdPostSetup, Audiences: []AudienceKind{AudienceVM}}

	base.OnFailure = Continue
	if err := Fire(context.Background(), io.Discard, base, "vm-setup", nil); err != nil {
		t.Errorf("Continue mode returned %v, want nil", err)
	}
	base.OnFailure = Abort
	if err := Fire(context.Background(), io.Discard, base, "vm-setup", nil); err == nil {
		t.Error("Abort mode returned nil, want an error")
	}
}
