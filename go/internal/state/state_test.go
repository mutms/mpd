package state

import (
	"os"
	"path/filepath"
	"testing"
)

func storeWith(t *testing.T, files map[string]string) Store {
	t.Helper()
	dir := t.TempDir()
	for name, body := range files {
		path := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	return NewAt(dir)
}

// `mpd list` on a fresh VM must print "none", not fail.
func TestMissingFilesAreEmptyNotAnError(t *testing.T) {
	s := NewAt(t.TempDir())
	if got := s.Projects(); len(got) != 0 {
		t.Errorf("Projects() = %d, want 0", len(got))
	}
	if got := s.Databases(); len(got) != 0 {
		t.Errorf("Databases() = %d, want 0", len(got))
	}
}

func TestMalformedJSONIsEmptyNotAPanic(t *testing.T) {
	s := storeWith(t, map[string]string{"projects.json": "{not json"})
	if got := s.Projects(); len(got) != 0 {
		t.Errorf("Projects() = %d, want 0", len(got))
	}
}

func TestProjectsAreSortedByName(t *testing.T) {
	s := storeWith(t, map[string]string{"projects.json": `{"projects":[
		{"name":"zeta","configured":true},
		{"name":"alpha","configured":true},
		{"name":"mid","configured":true}
	]}`})
	got := s.Projects()
	want := []string{"alpha", "mid", "zeta"}
	if len(got) != len(want) {
		t.Fatalf("got %d projects, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i].Name != want[i] {
			t.Errorf("projects[%d] = %q, want %q", i, got[i].Name, want[i])
		}
	}
}

func TestProjectStatus(t *testing.T) {
	cases := []struct {
		name string
		p    Project
		want string
	}{
		{"fresh init: unconfigured", Project{Name: "a"}, "not initialised"},
		{"configured and started", Project{Name: "a", Configured: true, Autostart: true}, "started"},
		{"configured and stopped", Project{Name: "a", Configured: true, Autostart: false}, "stopped"},
		{"autostart while unconfigured is still not initialised",
			Project{Name: "a", Autostart: true}, "not initialised"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.p.Status(); got != tc.want {
				t.Errorf("Status() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestMainURL(t *testing.T) {
	running := Project{Configured: true, Autostart: true}

	// kind "web" wins.
	p := running
	p.URLs = []ProjectURL{
		{Label: "mail", Kind: "mail", URL: "https://mail/"},
		{Label: "main", Kind: "web", URL: "https://web/"},
	}
	if got := p.MainURL(); got != "https://web/" {
		t.Errorf("MainURL() = %q, want the web URL", got)
	}

	// label "main" also wins when no kind is web.
	p.URLs = []ProjectURL{
		{Label: "other", Kind: "tunnel", URL: "https://tunnel/"},
		{Label: "main", Kind: "other", URL: "https://main/"},
	}
	if got := p.MainURL(); got != "https://main/" {
		t.Errorf("MainURL() = %q, want the main-labelled URL", got)
	}

	// Otherwise the first.
	p.URLs = []ProjectURL{{Label: "a", Kind: "x", URL: "https://first/"}}
	if got := p.MainURL(); got != "https://first/" {
		t.Errorf("MainURL() = %q, want the first URL", got)
	}
}

// A stopped project keeps its URL: stop does not withdraw the vhost,
// cert or DNS record.
func TestMainURLSurvivesStop(t *testing.T) {
	p := Project{Configured: true, Autostart: false,
		URLs: []ProjectURL{{Kind: "web", URL: "https://web/"}}}
	if got := p.MainURL(); got != "https://web/" {
		t.Errorf("MainURL() = %q for a stopped project, want the web URL", got)
	}
}

// An unconfigured project has no address to publish under.
func TestMainURLSuppressedWhenUnconfigured(t *testing.T) {
	p := Project{Autostart: true,
		URLs: []ProjectURL{{Kind: "web", URL: "https://web/"}}}
	if got := p.MainURL(); got != "" {
		t.Errorf("MainURL() = %q when unconfigured, want empty", got)
	}
}

func TestGroupings(t *testing.T) {
	projects := []Project{
		{Name: "b", Configured: true, DatabaseID: "postgres-latest"},
		{Name: "a", Configured: true, DatabaseID: "postgres-latest"},
		{Name: "c", Configured: true},
		{Name: "d"}, // unconfigured, no db — must not be counted anywhere
	}
	byDB := ProjectNamesByDatabase(projects)
	got := byDB["postgres-latest"]
	if len(got) != 2 || got[0] != "a" || got[1] != "b" {
		t.Errorf("ProjectNamesByDatabase() = %v, want sorted [a b]", got)
	}
}
