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

// `mpd list` on a VM that has never created anything must print "none",
// not fail — so absent files read as empty rather than erroring.
func TestMissingFilesAreEmptyNotAnError(t *testing.T) {
	s := NewAt(t.TempDir())
	if got := s.Projects(); len(got) != 0 {
		t.Errorf("Projects() = %d, want 0", len(got))
	}
	if got := s.Databases(); len(got) != 0 {
		t.Errorf("Databases() = %d, want 0", len(got))
	}
	if _, ok := s.Runtime("php"); ok {
		t.Error("Runtime() = ok for a missing file")
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
		{"name":"zeta","runtimeName":"php","requested":"running"},
		{"name":"alpha","runtimeName":"php","requested":"stopped"},
		{"name":"mid","runtimeName":"node","requested":"running"}
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

func TestMainURL(t *testing.T) {
	running := Project{RuntimeName: "php", Requested: "running"}

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

// A stopped project's URL would link to nothing, so it is suppressed.
func TestMainURLSuppressedWhenNotRunning(t *testing.T) {
	p := Project{RuntimeName: "php", Requested: "stopped",
		URLs: []ProjectURL{{Kind: "web", URL: "https://web/"}}}
	if got := p.MainURL(); got != "" {
		t.Errorf("MainURL() = %q for a stopped project, want empty", got)
	}
	p = Project{RuntimeName: "", Requested: "running",
		URLs: []ProjectURL{{Kind: "web", URL: "https://web/"}}}
	if got := p.MainURL(); got != "" {
		t.Errorf("MainURL() = %q with no runtime, want empty", got)
	}
}

func TestGroupings(t *testing.T) {
	projects := []Project{
		{Name: "b", RuntimeName: "php", DatabaseID: "postgres-latest"},
		{Name: "a", RuntimeName: "php", DatabaseID: "postgres-latest"},
		{Name: "c", RuntimeName: "node"},
		{Name: "d"}, // no runtime, no db — must not be counted anywhere
	}
	byDB := ProjectNamesByDatabase(projects)
	got := byDB["postgres-latest"]
	if len(got) != 2 || got[0] != "a" || got[1] != "b" {
		t.Errorf("ProjectNamesByDatabase() = %v, want sorted [a b]", got)
	}
}

func TestRuntimeMeta(t *testing.T) {
	s := storeWith(t, map[string]string{
		"runtimes/php/meta.json": `{"name":"php","runtime":"php","ip":"10.163.150.100","requested":"running"}`,
	})
	r, ok := s.Runtime("php")
	if !ok {
		t.Fatal("Runtime(\"php\") not found")
	}
	if r.IP != "10.163.150.100" || r.Requested != "running" {
		t.Errorf("Runtime() = %+v", r)
	}
}
