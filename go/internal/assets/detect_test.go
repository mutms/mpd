package assets

import (
	"os"
	"path/filepath"
	"testing"
)

// fixtureTree writes a minimal asset tree defining project types, each
// with the detect.files list given.
func fixtureTree(t *testing.T, types map[string][]string) Tree {
	t.Helper()
	root := t.TempDir()
	for name, files := range types {
		dir := filepath.Join(root, VMDir, "project_types", name)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		cfg := `{"detect":{`
		if name == "html" {
			cfg += `"fallback":true,`
		}
		cfg += `"files":[`
		for i, f := range files {
			if i > 0 {
				cfg += ","
			}
			cfg += `"` + f + `"`
		}
		cfg += `]}}`
		if err := os.WriteFile(filepath.Join(dir, "configuration.json"), []byte(cfg), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return NewAt(root)
}

// projectDir writes a project source tree containing the given files.
func projectDir(t *testing.T, files ...string) string {
	t.Helper()
	dir := t.TempDir()
	for _, f := range files {
		full := filepath.Join(dir, f)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestDetectTypeFromTree(t *testing.T) {
	tree := fixtureTree(t, map[string][]string{
		"astro":    {"astro.config.mjs", "astro.config.ts"},
		"moodle":   {"version.php", "public/version.php"},
		"html":     {"index.html"},
		"exttests": {"downloadtests.md5"},
	})

	tests := []struct {
		name  string
		files []string
		want  []string
	}{
		{"astro by config file", []string{"astro.config.mjs"}, []string{"astro"}},
		{"astro by alternate extension", []string{"astro.config.ts"}, []string{"astro"}},
		{"moodle by version.php", []string{"version.php"}, []string{"moodle"}},
		{"moodle 5.x public layout", []string{"public/version.php"}, []string{"moodle"}},
		{"empty tree matches nothing", nil, nil},
		{"unrelated tree matches nothing", []string{"README.md", "go.mod"}, nil},
		// The reported bug: a directory named for something else, holding
		// an astro checkout, must not fall through to the moodle default.
		{"name is irrelevant", []string{"astro.config.mjs", "README.md"}, []string{"astro"}},
		// Both claim it — the caller must be told, not handed a winner.
		{"ambiguous tree returns every match", []string{"astro.config.mjs", "version.php"},
			[]string{"astro", "moodle"}},
		{"fallback type alone", []string{"index.html"}, []string{"html"}},
		// html is the "we do not know" type: any specific match wins.
		{"specific type beats fallback", []string{"index.html", "downloadtests.md5"},
			[]string{"exttests"}},
		{"fallback dropped beside an ambiguous pair", []string{"index.html", "astro.config.mjs", "version.php"},
			[]string{"astro", "moodle"}},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := tree.DetectTypeFromTree(projectDir(t, tc.files...))
			if len(got) != len(tc.want) {
				t.Fatalf("DetectTypeFromTree = %v, want %v", got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Fatalf("DetectTypeFromTree = %v, want %v", got, tc.want)
				}
			}
		})
	}
}

func TestDetectTypeFromTreeOnMissingDir(t *testing.T) {
	tree := fixtureTree(t, map[string][]string{"astro": {"astro.config.mjs"}})
	if got := tree.DetectTypeFromTree("/nonexistent/project/dir"); got != nil {
		t.Errorf("DetectTypeFromTree on a missing dir = %v, want nil", got)
	}
}

// A detect entry must not be able to reach outside the project directory
// and match on some unrelated file elsewhere on the VM.
func TestDetectTypeFromTreeRejectsEscapingPaths(t *testing.T) {
	tree := fixtureTree(t, map[string][]string{
		"sneaky": {"../outside.txt", "/etc/hostname", ""},
	})
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(filepath.Dir(dir), "outside.txt"),
		[]byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := tree.DetectTypeFromTree(dir); got != nil {
		t.Errorf("DetectTypeFromTree matched an escaping path: %v", got)
	}
}
