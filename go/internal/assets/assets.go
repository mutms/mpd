// Package assets inspects the shipped asset tree under /opt/mpd/assets.
// It only reads layout — what project types exist, what a type declares.
package assets

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Dir is the bind-mounted asset tree, identical on the VM and inside
// every container.
const Dir = "/opt/mpd/assets"

// RuntimeDir is the unified runtime's asset directory under Dir.
const RuntimeDir = "runtime"

// Tree reads one asset directory; the path is a field for tests.
type Tree struct{ dir string }

// New returns a Tree over the real asset directory.
func New() Tree { return Tree{dir: Dir} }

// NewAt returns a Tree over an arbitrary directory, for tests.
func NewAt(dir string) Tree { return Tree{dir: dir} }

// ProjectTypeConfig locates the assets that implement a project type.
// `assetsType` lets a type reuse another's scripts, so callers must
// resolve through here, never assume runtime/project_types/<type>/.
type ProjectTypeConfig struct {
	// AssetsType is the directory holding the type's scripts.
	AssetsType string `json:"assetsType"`
	// DetectFiles are paths, relative to the project directory, whose
	// presence identifies a source tree as this type. Any one is enough.
	DetectFiles []string
	// WaitForURL is set when `mpd start` should block until the
	// project's main URL answers; false for types whose server the
	// developer runs by hand.
	WaitForURL bool
}

// ProjectTypeConfig reads a project type's configuration.json, resolving
// which directory holds its scripts.
func (t Tree) ProjectTypeConfig(name string) (ProjectTypeConfig, bool) {
	if !t.HasProjectType(name) {
		return ProjectTypeConfig{}, false
	}
	cfg := ProjectTypeConfig{AssetsType: name, WaitForURL: true}

	data, err := os.ReadFile(t.typeFile(name, "configuration.json"))
	if err != nil {
		return cfg, true
	}
	var raw struct {
		AssetsType string `json:"assetsType"`
		Detect     struct {
			Files []string `json:"files"`
		} `json:"detect"`
		Start struct {
			// Pointer so an absent key keeps the default rather
			// than reading as false.
			WaitForURL *bool `json:"waitForURL"`
		} `json:"start"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return cfg, true
	}
	cfg.DetectFiles = raw.Detect.Files
	if raw.Start.WaitForURL != nil {
		cfg.WaitForURL = *raw.Start.WaitForURL
	}
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

// HasTypeFile reports whether a project type ships a given file, so a
// caller can skip an optional script rather than exec a path that is not
// there. Takes the resolved ProjectTypeConfig.AssetsType, like
// TypeScript, so `assetsType` delegation is honoured.
func (t Tree) HasTypeFile(assetsType, rel string) bool {
	_, err := os.Stat(t.typeFile(assetsType, rel))
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

// DetectTypeFromTree infers project types from the project directory,
// matching each type's `detect.files`. Every matching type is returned,
// in sorted order: the caller must not silently pick a winner.
func (t Tree) DetectTypeFromTree(dir string) []string {
	var matched []string
	for _, ty := range t.AllProjectTypes() {
		cfg, ok := t.ProjectTypeConfig(ty)
		if !ok {
			continue
		}
		for _, rel := range cfg.DetectFiles {
			// Reject anything that could climb out of the project
			// directory.
			if rel == "" || filepath.IsAbs(rel) || strings.Contains(rel, "..") {
				continue
			}
			if _, err := os.Stat(filepath.Join(dir, rel)); err == nil {
				matched = append(matched, ty)
				break
			}
		}
	}
	return matched
}
