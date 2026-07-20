// Package state reads mpd's persisted state under /var/lib/mpd/state/.
//
// These files are the contract shared between the Swift and Go binaries
// during the port, and between mpd and out-of-process consumers (the
// portal reads them read-only). Field names must match the Swift
// Codable structs exactly.
//
// Reading is deliberately forgiving: a missing file is an empty result,
// not an error. `mpd list` on a VM that has never created a project
// should print "none", not fail. Writing — which must not be forgiving —
// lands with the mutating verbs.
package state

import (
	"encoding/json"
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
