// Package assets inspects the shipped asset tree under /opt/mpd/assets.
//
// Assets are the language-agnostic half of mpd: runtimes, project types
// and tools are shell, unchanged by the Go port. This package only reads
// their layout — what runtimes exist, what a runtime declares — never
// their behaviour.
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

// Tree reads one asset directory. The path is a field so tests can point
// at a fixture.
type Tree struct{ dir string }

// New returns a Tree over the real asset directory.
func New() Tree { return Tree{dir: Dir} }

// NewAt returns a Tree over an arbitrary directory, for tests.
func NewAt(dir string) Tree { return Tree{dir: dir} }

// RuntimeNames lists every runtime mpd could create, sorted.
//
// A directory counts as a runtime when it contains build.sh — the script
// that provisions it. Presence of configuration.json is not the test:
// project types have one too.
func (t Tree) RuntimeNames() []string {
	entries, err := os.ReadDir(filepath.Join(t.dir, "runtimes"))
	if err != nil {
		return nil
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if _, err := os.Stat(filepath.Join(t.dir, "runtimes", e.Name(), "build.sh")); err == nil {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names
}

// RuntimeConfig is the part of a runtime's configuration.json mpd reads.
type RuntimeConfig struct {
	// IPOctet is the runtime's host octet inside the VM's /24. The asset
	// declares only the octet, never a full address, so the same asset is
	// correct on every VM.
	IPOctet int `json:"ipOctet"`
	// DefaultSidecars are started with the runtime.
	DefaultSidecars []string `json:"defaultSidecars"`
}

// RuntimeConfig reads a runtime's configuration.json.
func (t Tree) RuntimeConfig(name string) (RuntimeConfig, bool) {
	data, err := os.ReadFile(filepath.Join(t.dir, "runtimes", name, "configuration.json"))
	if err != nil {
		return RuntimeConfig{}, false
	}
	var cfg RuntimeConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return RuntimeConfig{}, false
	}
	return cfg, true
}

// ProjectTypeConfig locates the assets that implement a project type.
//
// A type's scripts do not always live under the runtime it runs on:
// `assetsType`/`assetsRuntime` let a type reuse another's scripts, so
// callers must resolve through here rather than assuming
// runtimes/<runtime>/project_types/<type>/.
type ProjectTypeConfig struct {
	// AssetsType is the directory holding the type's scripts.
	AssetsType string `json:"assetsType"`
	// AssetsRuntime is the runtime that owns that directory.
	AssetsRuntime string
	// StopSystemd is set when stopping the project needs an explicit
	// `systemctl stop mpd-<project>` inside the runtime — types that run
	// a dev server (astro) rather than serving through the frontdoor.
	StopSystemd bool
}

// ProjectTypeConfig reads a project type's configuration.json, resolving
// which runtime directory holds its scripts.
func (t Tree) ProjectTypeConfig(name string) (ProjectTypeConfig, bool) {
	runtime, found := t.findProjectType(name)
	if !found {
		return ProjectTypeConfig{}, false
	}
	cfg := ProjectTypeConfig{AssetsType: name, AssetsRuntime: runtime}

	data, err := os.ReadFile(filepath.Join(t.dir, "runtimes", runtime,
		"project_types", name, "configuration.json"))
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
	if raw.AssetsType == "" || raw.AssetsType == name {
		return cfg, true
	}
	// The type delegates to another type's scripts; find who owns those.
	cfg.AssetsType = raw.AssetsType
	if owner, ok := t.findProjectType(raw.AssetsType); ok {
		cfg.AssetsRuntime = owner
	}
	return cfg, true
}

// findProjectType returns the runtime whose project_types/ contains name.
func (t Tree) findProjectType(name string) (string, bool) {
	for _, runtime := range t.RuntimeNames() {
		path := filepath.Join(t.dir, "runtimes", runtime, "project_types", name, "configuration.json")
		if _, err := os.Stat(path); err == nil {
			return runtime, true
		}
	}
	return "", false
}

// ProjectTypeSidecars lists sidecar roles a project type requires.
func (t Tree) ProjectTypeSidecars(name string) ([]string, bool) {
	runtime, found := t.findProjectType(name)
	if !found {
		return nil, false
	}
	data, err := os.ReadFile(filepath.Join(t.dir, "runtimes", runtime,
		"project_types", name, "configuration.json"))
	if err != nil {
		return nil, false
	}
	var raw struct {
		Sidecars []string `json:"sidecars"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, false
	}
	return raw.Sidecars, true
}

// DefaultRuntimeForType returns the runtime a project type runs on.
func (t Tree) DefaultRuntimeForType(name string) (string, bool) {
	return t.findProjectType(name)
}

// HasFile reports whether a path exists under the asset tree.
func (t Tree) HasFile(rel string) bool {
	_, err := os.Stat(filepath.Join(t.dir, rel))
	return err == nil
}

// AllProjectTypes lists every project type across all runtimes, sorted.
func (t Tree) AllProjectTypes() []string {
	var types []string
	for _, rt := range t.RuntimeNames() {
		entries, err := os.ReadDir(filepath.Join(t.dir, "runtimes", rt, "project_types"))
		if err != nil {
			continue
		}
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			if t.HasFile(filepath.Join("runtimes", rt, "project_types", e.Name(), "configuration.json")) {
				types = append(types, e.Name())
			}
		}
	}
	sort.Strings(types)
	return types
}

// DetectTypeFromName infers a project type from the project's name:
// an exact match on a type name, else a `-<suffix>` match for types that
// opt in by declaring nameSuffix.
//
// Only opt-in types participate in suffix matching — a generic type like
// moodle must not absorb every name ending in "-moodle-ish".
func (t Tree) DetectTypeFromName(name string) string {
	types := t.AllProjectTypes()
	for _, ty := range types {
		if ty == name {
			return ty
		}
	}
	for _, ty := range types {
		runtime, ok := t.findProjectType(ty)
		if !ok {
			continue
		}
		data, err := os.ReadFile(filepath.Join(t.dir, "runtimes", runtime,
			"project_types", ty, "configuration.json"))
		if err != nil {
			continue
		}
		var raw struct {
			NameSuffix string `json:"nameSuffix"`
		}
		if err := json.Unmarshal(data, &raw); err != nil || raw.NameSuffix == "" {
			continue
		}
		if strings.HasSuffix(name, "-"+raw.NameSuffix) {
			return ty
		}
	}
	return ""
}
