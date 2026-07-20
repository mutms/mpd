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
