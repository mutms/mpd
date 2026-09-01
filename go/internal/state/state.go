// Package state reads and writes mpd's persisted state under
// /var/lib/mpd/state/.
//
// The files are a contract with out-of-process readers (the portal,
// jq in shell tools); renaming a field breaks readers mpd cannot see.
// Reads are forgiving — a missing file is an empty result; writes are
// atomic and report every failure.
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

// Store reads state from a directory; tests point it at a fixture.
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
//
// Autostart is the project's whole lifecycle intent: true after `mpd
// start`, false after `mpd stop`; a reboot honours it. There is no
// stored observed state to disagree with it — a start that does not
// fully succeed sets it back to false, keeping the flag honest in the
// safe direction.
type Project struct {
	Name            string `json:"name"`
	Type            string `json:"type"`
	DatabaseID      string `json:"databaseId"`
	DatabaseEngine  string `json:"databaseEngine"`
	DatabaseVersion string `json:"databaseVersion"`
	// Configured is set once `mpd start` has run a project type's
	// configure.sh; before that a project has no URLs, DB or certs.
	Configured bool         `json:"configured"`
	Autostart  bool         `json:"autostart"`
	URLs       []ProjectURL `json:"urls"`
}

// Status returns the single lifecycle word for a project: "not
// initialised" until `mpd start` has configured it, else "started" or
// "stopped" from the Autostart intent.
func (p Project) Status() string {
	if !p.Configured {
		return "not initialised"
	}
	if p.Autostart {
		return "started"
	}
	return "stopped"
}

// MainURL is the URL to show for a project: the first entry whose kind
// is "web" or whose label is "main", else the first; empty when the
// project is unconfigured or has no URLs.
//
// Deliberately not gated on the project running: the vhost, certificate
// and DNS record survive a stop, so the address stays correct even when
// nothing serves behind it.
func (p Project) MainURL() string {
	if !p.Configured {
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
//
// Status caches the observed running/stopped state. Autostart is the
// sticky intent set by `mpd --db-start` / `--db-stop`; a project
// starting a database it needs does not change it.
type Database struct {
	DatabaseID    string `json:"databaseId"`
	Engine        string `json:"engine"`
	Version       string `json:"version"`
	ContainerName string `json:"containerName"`
	Status        string `json:"status"`
	Autostart     bool   `json:"autostart"`
}

// Service is one extra service container's persisted intent, as stored
// in services.json. Presence means installed; Autostart is the sticky
// run-on-boot intent set by `--service-start`/`--service-stop`. A
// service started on demand for a project (MPD_REQUIRE_SERVICES) does
// not set it.
type Service struct {
	Name      string `json:"name"`
	Autostart bool   `json:"autostart"`
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

// Config is VM-wide operator config, detected once at `mpd --vm-setup`.
type Config struct {
	UID  string `json:"uid"`
	User string `json:"user"`

	// LastUpgradeVersion and LastUpgradeAt record the most recent
	// successful `mpd --vm-upgrade`. Written by the upgrade because
	// nothing can derive it afterwards; empty on a VM never upgraded.
	LastUpgradeVersion string `json:"lastUpgradeVersion,omitempty"`
	LastUpgradeAt      string `json:"lastUpgradeAt,omitempty"`
}

// Config reads config.json; a missing file yields the zero value.
func (s Store) Config() Config {
	var c Config
	readJSON(filepath.Join(s.dir, "config.json"), &c)
	return c
}

// SaveConfig writes config.json.
func (s Store) SaveConfig(c Config) error { return s.writeJSON("config.json", c) }

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

// readJSON decodes path into v, reporting whether it succeeded. A
// missing or malformed file leaves v untouched.
func readJSON(path string, v any) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	return json.Unmarshal(data, v) == nil
}

// Services returns every installed extra service's intent.
func (s Store) Services() []Service {
	var wrapper struct {
		Services []Service `json:"services"`
	}
	readJSON(filepath.Join(s.dir, "services.json"), &wrapper)
	sort.Slice(wrapper.Services, func(i, j int) bool {
		return wrapper.Services[i].Name < wrapper.Services[j].Name
	})
	return wrapper.Services
}

// SaveServices replaces services.json.
func (s Store) SaveServices(entries []Service) error {
	if entries == nil {
		entries = []Service{}
	}
	return s.writeJSON("services.json", struct {
		Services []Service `json:"services"`
	}{entries})
}

// UpsertService records one service's intent, keeping the rest.
func (s Store) UpsertService(entry Service) error {
	services := s.Services()
	for i, existing := range services {
		if existing.Name == entry.Name {
			services[i] = entry
			return s.SaveServices(services)
		}
	}
	return s.SaveServices(append(services, entry))
}

// DeleteService removes one service's intent (uninstalled).
func (s Store) DeleteService(name string) error {
	services := s.Services()
	var kept []Service
	for _, existing := range services {
		if existing.Name != name {
			kept = append(kept, existing)
		}
	}
	return s.SaveServices(kept)
}

// SaveDatabases replaces databases.json.
func (s Store) SaveDatabases(entries []Database) error {
	if entries == nil {
		entries = []Database{}
	}
	return s.writeJSON("databases.json", struct {
		Databases []Database `json:"databases"`
	}{entries})
}

// SetDatabaseAutostart records a database's autostart intent, keeping
// the rest of its cached record. A no-op when the id is unknown: the
// cache is rebuilt from podman, so an absent database has nothing to
// remember.
func (s Store) SetDatabaseAutostart(id string, v bool) error {
	dbs := s.Databases()
	for i := range dbs {
		if dbs[i].DatabaseID == id {
			dbs[i].Autostart = v
			return s.SaveDatabases(dbs)
		}
	}
	return nil
}

// SaveProjects replaces projects.json.
//
// Empty slices are normalised to `[]` rather than nil at both levels: a
// nil slice marshals to `null`, and consumers would have to treat
// absent, null and empty as the same thing.
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
	// `name` may be a relative path like "services/mailpit.json".
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
