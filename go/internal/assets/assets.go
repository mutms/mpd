// Package assets inspects the shipped asset tree under /opt/mpd/assets.
//
// Assets are the language-agnostic half of mpd: the runtime, project
// types and tools are shell, unchanged by the Go port. This package only
// reads their layout — what project types exist, what a type declares —
// never their behaviour.
package assets

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
)

// Dir is the bind-mounted asset tree, identical on the VM and inside
// every container.
const Dir = "/opt/mpd/assets"

// RuntimeDir is the unified runtime's asset directory under Dir.
const RuntimeDir = "runtime"

// Tree reads one asset directory. The path is a field so tests can point
// at a fixture.
type Tree struct{ dir string }

// New returns a Tree over the real asset directory.
func New() Tree { return Tree{dir: Dir} }

// NewAt returns a Tree over an arbitrary directory, for tests.
func NewAt(dir string) Tree { return Tree{dir: dir} }

// ProjectTypeConfig locates the assets that implement a project type.
//
// A type's scripts do not always live under its own directory:
// `assetsType` lets a type reuse another's scripts, so callers must
// resolve through here rather than assuming
// runtime/project_types/<type>/.
type ProjectTypeConfig struct {
	// AssetsType is the directory holding the type's scripts.
	AssetsType string `json:"assetsType"`
	// StopSystemd is set when stopping the project needs an explicit
	// `systemctl stop mpd-<project>` inside the runtime — types that run
	// a dev server (astro) rather than serving through the frontdoor.
	StopSystemd bool
}

// ProjectTypeConfig reads a project type's configuration.json, resolving
// which directory holds its scripts.
func (t Tree) ProjectTypeConfig(name string) (ProjectTypeConfig, bool) {
	if !t.HasProjectType(name) {
		return ProjectTypeConfig{}, false
	}
	cfg := ProjectTypeConfig{AssetsType: name}

	data, err := os.ReadFile(t.typeFile(name, "configuration.json"))
	if err != nil {
		return cfg, true
	}
	var raw struct {
		AssetsType string `json:"assetsType"`
		Stop       struct {
			SystemdStop bool `json:"systemdStop"`
		} `json:"stop"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return cfg, true
	}
	cfg.StopSystemd = raw.Stop.SystemdStop
	if raw.AssetsType != "" && raw.AssetsType != name {
		// The type delegates to another type's scripts.
		cfg.AssetsType = raw.AssetsType
	}
	return cfg, true
}

// HasProjectType reports whether a project type exists in the tree.
func (t Tree) HasProjectType(name string) bool {
	_, err := os.Stat(t.typeFile(name, "configuration.json"))
	return err == nil
}

// typeFile is a path inside a project type's asset directory.
func (t Tree) typeFile(typeName, rel string) string {
	return filepath.Join(t.dir, RuntimeDir, "project_types", typeName, rel)
}

// TypeScript is the in-container absolute path of a project-type script,
// e.g. TypeScript("moodle", "scripts/configure.sh"). Callers pass the
// resolved ProjectTypeConfig.AssetsType so `assetsType` delegation is
// honoured. Always under Dir — the tree is bind-mounted at the same path
// inside every container.
func TypeScript(assetsType, rel string) string {
	return filepath.Join(Dir, RuntimeDir, "project_types", assetsType, rel)
}

// HasFile reports whether a path exists under the asset tree.
func (t Tree) HasFile(rel string) bool {
	_, err := os.Stat(filepath.Join(t.dir, rel))
	return err == nil
}

// AllProjectTypes lists every project type, sorted.
func (t Tree) AllProjectTypes() []string {
	var types []string
	entries, err := os.ReadDir(filepath.Join(t.dir, RuntimeDir, "project_types"))
	if err != nil {
		return nil
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if t.HasProjectType(e.Name()) {
			types = append(types, e.Name())
		}
	}
	sort.Strings(types)
	return types
}

// DetectTypeFromName infers a project type from the project's name: an
// exact match on a type name ("moodle" creates a moodle project).
func (t Tree) DetectTypeFromName(name string) string {
	for _, ty := range t.AllProjectTypes() {
		if ty == name {
			return ty
		}
	}
	return ""
}
