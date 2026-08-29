package hooks

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Diagnostics cross-reference the asset tree against the event
// catalogue: unknown events, wrong audiences, revision bumps. All three
// produce silence at dispatch time, so a warning here is the only thing
// that surfaces them. Warnings never fail a run.

// CatalogueEntry is what the diagnostic knows about one event.
type CatalogueEntry struct {
	Name      string
	Revision  int
	Audiences []AudienceKind
}

// Catalogue is every event mpd can fire. Add new events here, or their
// hook directories are reported as orphans.
func Catalogue() []CatalogueEntry {
	return []CatalogueEntry{
		{EventMpdPostSetup, 1, []AudienceKind{AudienceVM, AudienceRuntime}},
		{EventMpdPreStop, 1, []AudienceKind{AudienceDatabase}},
		{EventProjectPreStart, 1, []AudienceKind{AudienceDatabase}},
		{EventProjectPreStop, 1, []AudienceKind{AudienceRuntime}},
		{EventProjectPostStart, 1, []AudienceKind{AudienceRuntime}},
	}
}

// StateFile records the revision each event was last seen at, so a bump
// is reported once rather than on every run.
const StateFile = "hooks-state.json"

type diagState struct {
	Revisions map[string]int `json:"revisions"`
}

// foundDir is one `hooks/<event>.d` directory in the asset tree.
type foundDir struct {
	EventName    string
	RelativePath string
	Kind         AudienceKind
}

// Diagnose walks the asset tree, prints warnings, and stamps current
// revisions. It returns the warnings so tests need not parse output.
func Diagnose(out io.Writer, stateDir string) []string {
	byName := map[string]CatalogueEntry{}
	for _, e := range Catalogue() {
		byName[e.Name] = e
	}

	var warnings []string
	for _, found := range walkHookDirs() {
		entry, known := byName[found.EventName]
		if !known {
			warnings = append(warnings, fmt.Sprintf(
				"Hook for unknown event '%s' at %s; remove or move.",
				found.EventName, found.RelativePath))
			continue
		}
		fires := false
		for _, a := range entry.Audiences {
			if a == found.Kind {
				fires = true
				break
			}
		}
		if !fires {
			warnings = append(warnings, fmt.Sprintf(
				"Hook at %s subscribes to event '%s' but the event no longer fires on this audience.",
				found.RelativePath, found.EventName))
		}
	}

	state := loadDiagState(stateDir)
	for _, entry := range Catalogue() {
		if last, seen := state.Revisions[entry.Name]; seen && last != entry.Revision {
			warnings = append(warnings, fmt.Sprintf(
				"Event '%s' revised (rev %d → rev %d); review hooks under hooks/%s.d/ for changed env vars.",
				entry.Name, last, entry.Revision, entry.Name))
		}
		state.Revisions[entry.Name] = entry.Revision
	}
	saveDiagState(stateDir, state)

	if len(warnings) > 0 && out != nil {
		fmt.Fprintln(out, "")
		fmt.Fprintln(out, "Hook diagnostics:")
		for _, w := range warnings {
			fmt.Fprintf(out, "  • %s\n", w)
		}
	}
	return warnings
}

// walkHookDirs finds every `hooks/<event>.d` directory, tagged with the
// audience that layer fires into.
func walkHookDirs() []foundDir {
	var found []foundDir

	found = append(found, scanLayer(
		filepath.Join(assetsDir, "runtime", "hooks"),
		"assets/runtime/hooks", AudienceRuntime)...)

	found = append(found, scanLayer(
		filepath.Join(assetsDir, "vm", "hooks"),
		"assets/vm/hooks", AudienceVM)...)

	typesDir := filepath.Join(assetsDir, "runtime", "project_types")
	for _, ty := range subdirs(typesDir) {
		found = append(found, scanLayer(
			filepath.Join(typesDir, ty, "hooks"),
			"assets/runtime/project_types/"+ty+"/hooks", AudienceRuntime)...)
	}
	for _, engine := range subdirs(filepath.Join(assetsDir, "databases")) {
		found = append(found, scanLayer(
			filepath.Join(assetsDir, "databases", engine, "hooks"),
			"assets/databases/"+engine+"/hooks", AudienceDatabase)...)
	}
	for _, svc := range subdirs(filepath.Join(assetsDir, "services")) {
		found = append(found, scanLayer(
			filepath.Join(assetsDir, "services", svc, "hooks"),
			"assets/services/"+svc+"/hooks", AudienceService)...)
	}
	return found
}

func scanLayer(dir, relative string, kind AudienceKind) []foundDir {
	var found []foundDir
	for _, name := range subdirs(dir) {
		if !strings.HasSuffix(name, ".d") {
			continue
		}
		found = append(found, foundDir{
			EventName:    strings.TrimSuffix(name, ".d"),
			RelativePath: relative + "/" + name,
			Kind:         kind,
		})
	}
	return found
}

func subdirs(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names
}

func loadDiagState(stateDir string) diagState {
	s := diagState{Revisions: map[string]int{}}
	data, err := os.ReadFile(filepath.Join(stateDir, StateFile))
	if err != nil {
		return s
	}
	if err := json.Unmarshal(data, &s); err != nil || s.Revisions == nil {
		return diagState{Revisions: map[string]int{}}
	}
	return s
}

func saveDiagState(stateDir string, s diagState) {
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		return
	}
	data, err := json.Marshal(s)
	if err != nil {
		return
	}
	_ = os.WriteFile(filepath.Join(stateDir, StateFile), data, 0o644)
}
