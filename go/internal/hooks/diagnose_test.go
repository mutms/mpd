package hooks

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func hasWarning(warnings []string, substr string) bool {
	for _, w := range warnings {
		if strings.Contains(w, substr) {
			return true
		}
	}
	return false
}

func TestCleanTreeProducesNoWarnings(t *testing.T) {
	withAssets(t, map[string]string{
		"databases/postgres/hooks/mpd-pre-stop.d/10-graceful-stop.sh": "",
		"vm/hooks/project-post-start.d/10-warm.sh":                    "",
	})
	if w := Diagnose(nil, t.TempDir()); len(w) != 0 {
		t.Errorf("warnings on a clean tree: %v", w)
	}
}

// A directory naming no known event is never scanned, so its hooks
// silently never run — the diagnostic is what surfaces it.
func TestUnknownEventIsReported(t *testing.T) {
	withAssets(t, map[string]string{
		"vm/hooks/project-pre-launch.d/10-x.sh": "",
	})
	w := Diagnose(nil, t.TempDir())
	if !hasWarning(w, "unknown event 'project-pre-launch'") {
		t.Errorf("warnings = %v, want an unknown-event warning", w)
	}
}

// project-pre-start fires on the DATABASE, so a copy under
// an empty hooks tree does nothing at all.
func TestWrongAudienceIsReported(t *testing.T) {
	withAssets(t, map[string]string{
		"vm/hooks/project-pre-start.d/10-x.sh": "",
	})
	w := Diagnose(nil, t.TempDir())
	if !hasWarning(w, "no longer fires on this audience") {
		t.Errorf("warnings = %v, want an audience warning", w)
	}

	// The same event under the right layer is fine.
	withAssets(t, map[string]string{
		"databases/postgres/hooks/project-pre-start.d/10-x.sh": "",
	})
	if w := Diagnose(nil, t.TempDir()); len(w) != 0 {
		t.Errorf("warnings for a correctly-placed hook: %v", w)
	}
}

func TestRevisionBumpIsReportedOnceThenStamped(t *testing.T) {
	withAssets(t, map[string]string{})
	stateDir := t.TempDir()

	// Seed a lower revision than the catalogue's.
	seed := diagState{Revisions: map[string]int{EventProjectPreStart: 0}}
	data, _ := json.Marshal(seed)
	if err := os.WriteFile(filepath.Join(stateDir, StateFile), data, 0o644); err != nil {
		t.Fatal(err)
	}

	w := Diagnose(nil, stateDir)
	if !hasWarning(w, "revised (rev 0 → rev 1)") {
		t.Fatalf("warnings = %v, want a revision-bump warning", w)
	}
	// Stamped, so the same bump is not re-reported every run.
	if w := Diagnose(nil, stateDir); hasWarning(w, "revised") {
		t.Errorf("bump reported twice: %v", w)
	}
}

// A missing stamp is not a bump — reporting one would warn on every
// new VM.
func TestFirstRunIsNotABump(t *testing.T) {
	withAssets(t, map[string]string{})
	if w := Diagnose(nil, t.TempDir()); len(w) != 0 {
		t.Errorf("warnings on first run: %v", w)
	}
}

func TestDiagnoseSurvivesMissingAssetTree(t *testing.T) {
	old := assetsDir
	assetsDir = filepath.Join(t.TempDir(), "absent")
	t.Cleanup(func() { assetsDir = old })
	if w := Diagnose(nil, t.TempDir()); len(w) != 0 {
		t.Errorf("warnings with no asset tree: %v", w)
	}
}

// The VM layer is diagnosed like any other.
func TestVMLayerIsDiagnosed(t *testing.T) {
	withAssets(t, map[string]string{
		"vm/hooks/mpd-pre-stop.d/10-x.sh": "",
	})
	w := Diagnose(nil, t.TempDir())
	if !hasWarning(w, "no longer fires on this audience") {
		t.Errorf("warnings = %v, want an audience warning for the vm layer", w)
	}

	withAssets(t, map[string]string{
		"vm/hooks/mpd-post-setup.d/50-x.sh": "",
		"vm/hooks/mpd-post-setup.d/50-y.sh": "",
	})
	if w := Diagnose(nil, t.TempDir()); len(w) != 0 {
		t.Errorf("warnings for correctly-placed mpd-post-setup hooks: %v", w)
	}
}
