// Package state reads mpd's persisted state under /var/lib/mpd/state/.
//
// These files are the contract between mpd and its out-of-process
// consumers: the portal renders them read-only, and in-runtime shell
// tools read them with jq. Renaming a field is a breaking change for
// readers that mpd cannot see.
//
// Reading is deliberately forgiving: a missing file is an empty result,
// not an error. `mpd list` on a VM that has never created a project
// should print "none", not fail. Writing — which must not be forgiving —
// lands with the mutating verbs.
package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

// Dir is where mpd keeps operational state. Wipe it to reset a VM.
const Dir = "/var/lib/mpd/state"

// Store reads state from a directory. The path is a field so tests can
// point at a fixture instead of the real VM.
type Store struct{ dir string }

// New returns a Store over the real state directory.
func New() Store { return Store{dir: Dir} }

// NewAt returns a Store over an arbitrary directory, for tests.
func NewAt(dir string) Store { return Store{dir: dir} }

// ProjectURL is one URL a project publishes.
type ProjectURL struct {
	Label string `json:"label"`
	Kind  string `json:"kind"`
	URL   string `json:"url"`
}

// Project is one registered project, as stored in projects.json.
type Project struct {
	Name            string       `json:"name"`
	Type            string       `json:"type"`
	DatabaseID      string       `json:"databaseId"`
	DatabaseEngine  string       `json:"databaseEngine"`
	DatabaseVersion string       `json:"databaseVersion"`
	RuntimeName     string       `json:"runtimeName"`
	Requested       string       `json:"requested"`
	URLs            []ProjectURL `json:"urls"`
}

// MainURL is the URL to show for a running project: the first entry whose
// kind is "web" or whose label is "main", else the first. Empty when the
// project is not running or has no URLs — a stopped project's URL would
// be a link to nothing.
func (p Project) MainURL() string {
	if p.RuntimeName == "" || p.Requested != "running" {
		return ""
	}
	for _, u := range p.URLs {
		if u.Kind == "web" || u.Label == "main" {
			return u.URL
		}
	}
	if len(p.URLs) > 0 {
		return p.URLs[0].URL
	}
	return ""
}

// Database is one DB container, as stored in databases.json.
type Database struct {
	DatabaseID    string `json:"databaseId"`
	Engine        string `json:"engine"`
	Version       string `json:"version"`
	ContainerName string `json:"containerName"`
	Status        string `json:"status"`
}

// Runtime is one runtime's persisted intent, from runtimes/<name>/meta.json.
type Runtime struct {
	Name      string `json:"name"`
	RuntimeID string `json:"runtime"`
	IP        string `json:"ip"`
	Requested string `json:"requested"`
}

// Projects returns every registered project, sorted by name.
func (s Store) Projects() []Project {
	var wrapper struct {
		Projects []Project `json:"projects"`
	}
	readJSON(filepath.Join(s.dir, "projects.json"), &wrapper)
	sort.Slice(wrapper.Projects, func(i, j int) bool {
		return wrapper.Projects[i].Name < wrapper.Projects[j].Name
	})
	return wrapper.Projects
}

// Databases returns every known DB container.
func (s Store) Databases() []Database {
	var wrapper struct {
		Databases []Database `json:"databases"`
	}
	readJSON(filepath.Join(s.dir, "databases.json"), &wrapper)
	return wrapper.Databases
}

// Runtime returns one runtime's persisted intent, and whether it exists.
func (s Store) Runtime(name string) (Runtime, bool) {
	var r Runtime
	if !readJSON(filepath.Join(s.dir, "runtimes", name, "meta.json"), &r) {
		return Runtime{}, false
	}
	return r, true
}

// RuntimeNames lists the runtimes that have a state directory, sorted.
//
// The cache, not podman: this is what mpd believes exists, and the
// difference from what podman reports is exactly what a cache rebuild
// has to reconcile.
func (s Store) RuntimeNames() []string {
	entries, err := os.ReadDir(filepath.Join(s.dir, "runtimes"))
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

// Config is VM-wide operator config, detected once at `mpd --vm-setup`.
type Config struct {
	UID  string `json:"uid"`
	User string `json:"user"`
}

// Config reads config.json; a missing file yields the zero value.
func (s Store) Config() Config {
	var c Config
	readJSON(filepath.Join(s.dir, "config.json"), &c)
	return c
}

// SaveConfig writes config.json.
func (s Store) SaveConfig(c Config) error { return s.writeJSON("config.json", c) }

// ProjectsByRuntime counts projects per runtime name.
func ProjectsByRuntime(projects []Project) map[string]int {
	counts := map[string]int{}
	for _, p := range projects {
		if p.RuntimeName != "" {
			counts[p.RuntimeName]++
		}
	}
	return counts
}

// ProjectNamesByDatabase maps a databaseId to the sorted names of the
// projects using it.
func ProjectNamesByDatabase(projects []Project) map[string][]string {
	byDB := map[string][]string{}
	for _, p := range projects {
		if p.DatabaseID != "" {
			byDB[p.DatabaseID] = append(byDB[p.DatabaseID], p.Name)
		}
	}
	for _, names := range byDB {
		sort.Strings(names)
	}
	return byDB
}

// readJSON decodes path into v, reporting whether it succeeded. A missing
// or malformed file leaves v untouched.
func readJSON(path string, v any) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	return json.Unmarshal(data, v) == nil
}

// --- Writing ----------------------------------------------------------
//
// Reads above are forgiving; writes are not. A half-written state file
// is worse than a missing one — readers would act on it — so writes go
// to a temp file and are renamed into place, and every failure is
// reported rather than swallowed.

// SaveDatabases replaces databases.json.
func (s Store) SaveDatabases(entries []Database) error {
	if entries == nil {
		entries = []Database{}
	}
	return s.writeJSON("databases.json", struct {
		Databases []Database `json:"databases"`
	}{entries})
}

// SaveProjects replaces projects.json.
//
// Empty slices are normalised to `[]` rather than left nil, at both
// levels. A nil slice marshals to `null`, and consumers — the portal's
// PHP, jq in shell tools — would then have to distinguish "key absent",
// "null" and "empty array", which all mean the same thing. Emitting a
// real empty array keeps that a non-question.
func (s Store) SaveProjects(projects []Project) error {
	if projects == nil {
		projects = []Project{}
	}
	normalised := make([]Project, len(projects))
	copy(normalised, projects)
	for i := range normalised {
		if normalised[i].URLs == nil {
			normalised[i].URLs = []ProjectURL{}
		}
	}
	return s.writeJSON("projects.json", struct {
		Projects []Project `json:"projects"`
	}{normalised})
}

func (s Store) writeJSON(name string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return fmt.Errorf("encoding %s: %w", name, err)
	}
	data = append(data, '\n')

	path := filepath.Join(s.dir, name)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", filepath.Dir(path), err)
	}
	// Pattern must be a bare filename: CreateTemp rejects separators, and
	// `name` may be a relative path like "runtimes/php/meta.json".
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(name)+".*")
	if err != nil {
		return fmt.Errorf("creating temp file for %s: %w", name, err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("writing %s: %w", name, err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("closing %s: %w", name, err)
	}
	if err := os.Chmod(tmpName, 0o644); err != nil {
		return fmt.Errorf("chmod %s: %w", name, err)
	}
	return os.Rename(tmpName, path)
}

// SaveRuntime writes one runtime's persisted intent.
func (s Store) SaveRuntime(r Runtime) error {
	return s.writeJSON(filepath.Join("runtimes", r.Name, "meta.json"), r)
}

// DeleteRuntime removes a runtime's state directory.
func (s Store) DeleteRuntime(name string) error {
	err := os.RemoveAll(filepath.Join(s.dir, "runtimes", name))
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// UpsertProject replaces a project record by name, or appends it.
func (s Store) UpsertProject(p Project) error {
	projects := s.Projects()
	for i := range projects {
		if projects[i].Name == p.Name {
			projects[i] = p
			return s.SaveProjects(projects)
		}
	}
	return s.SaveProjects(append(projects, p))
}

// DeleteProject removes a project record by name.
func (s Store) DeleteProject(name string) error {
	projects := s.Projects()
	kept := projects[:0]
	for _, p := range projects {
		if p.Name != name {
			kept = append(kept, p)
		}
	}
	return s.SaveProjects(kept)
}
