package vm

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testHosts() []RuntimeHost {
	return []RuntimeHost{
		{Patterns: []string{"mpd-130-php", "php", "php.runtime.130.mpd.test"},
			HostName: "php.runtime.130.mpd.test"},
		{Patterns: []string{"mpd-130-util", "util", "util.runtime.130.mpd.test"},
			HostName: "util.runtime.130.mpd.test"},
	}
}

func TestRenderSSHBlockMapsAliasesToFQDN(t *testing.T) {
	got := renderSSHBlock("skodak", testHosts())

	for _, want := range []string{
		"Host mpd-130-php php php.runtime.130.mpd.test",
		"    HostName php.runtime.130.mpd.test",
		"    User skodak",
		"    StrictHostKeyChecking no",
		"    UserKnownHostsFile /dev/null",
		"Host mpd-130-util util util.runtime.130.mpd.test",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("block is missing %q\n---\n%s", want, got)
		}
	}
	if !strings.HasPrefix(got, sshBlockStart) || !strings.HasSuffix(got, sshBlockEnd+"\n") {
		t.Errorf("block is not delimited by its markers:\n%s", got)
	}
}

// A runtime with no HostName would render a Host stanza that ssh resolves
// to the alias itself — a name that is deliberately not in DNS.
func TestRenderSSHBlockSkipsIncompleteHosts(t *testing.T) {
	got := renderSSHBlock("skodak", []RuntimeHost{
		{Patterns: []string{"mpd-130-php"}},
		{HostName: "php.runtime.130.mpd.test"},
	})
	if strings.Contains(got, "Host mpd-130-php") {
		t.Errorf("rendered a Host with no HostName:\n%s", got)
	}
	if strings.Contains(got, "HostName php.runtime") {
		t.Errorf("rendered a HostName with no Host:\n%s", got)
	}
}

// The developer's own entries must survive, and a second run must not
// stack a second copy of the block.
func TestStripBlockPreservesUserContentAndIsIdempotent(t *testing.T) {
	user := "Host forge\n    HostName forge.example.com\n    User petr\n"

	first := user + "\n" + renderSSHBlock("skodak", testHosts())
	stripped := strings.TrimRight(stripBlock(first), "\n")
	if stripped != strings.TrimRight(user, "\n") {
		t.Errorf("user content not preserved exactly:\n%q\nwant:\n%q",
			stripped, strings.TrimRight(user, "\n"))
	}

	second := stripped + "\n\n" + renderSSHBlock("skodak", testHosts())
	if second != first {
		t.Errorf("regeneration is not stable:\n%q\nwant:\n%q", second, first)
	}
	if n := strings.Count(second, sshBlockStart); n != 1 {
		t.Errorf("got %d start markers, want 1:\n%s", n, second)
	}
}

func TestStripBlockOnFileWithoutBlock(t *testing.T) {
	user := "Host forge\n    HostName forge.example.com"
	if got := stripBlock(user); got != user {
		t.Errorf("stripBlock mangled a file with no managed block: %q", got)
	}
}

// A start marker with no end marker takes the rest of the file, rather
// than leaving a stray marker that would compound on every run.
func TestStripBlockHandlesUnterminatedBlock(t *testing.T) {
	body := "Host forge\n    HostName forge.example.com\n" + sshBlockStart + "\nHost mpd-130-php\n"
	got := stripBlock(body)
	if strings.Contains(got, sshBlockStart) {
		t.Errorf("left a stray start marker: %q", got)
	}
	if !strings.Contains(got, "forge.example.com") {
		t.Errorf("dropped content above the marker: %q", got)
	}
}

// End-to-end through the file: a hand-written entry survives, the second
// run is a no-op, and the file is not world-readable.
func TestEnsureSSHConfigWritesPreservesAndRepeats(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	path := filepath.Join(home, ".ssh", "config")

	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("Host forge\n    HostName forge.example.com\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := EnsureSSHConfig(io.Discard, "skodak", testHosts()); err != nil {
		t.Fatalf("first run: %v", err)
	}
	first, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(first), "forge.example.com") {
		t.Errorf("hand-written entry lost:\n%s", first)
	}
	if !strings.Contains(string(first), "Host mpd-130-php php php.runtime.130.mpd.test") {
		t.Errorf("alias not written:\n%s", first)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Errorf("config mode is %o, want 600 — ssh rejects a group/world-writable config", perm)
	}

	if err := EnsureSSHConfig(io.Discard, "skodak", testHosts()); err != nil {
		t.Fatalf("second run: %v", err)
	}
	second, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(second) != string(first) {
		t.Errorf("second run changed the file:\n%s\nwant:\n%s", second, first)
	}
}

// No ~/.ssh at all — a sandbox VM before any key exists.
func TestEnsureSSHConfigCreatesMissingDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	if err := EnsureSSHConfig(io.Discard, "skodak", testHosts()); err != nil {
		t.Fatalf("EnsureSSHConfig: %v", err)
	}
	body, err := os.ReadFile(filepath.Join(home, ".ssh", "config"))
	if err != nil {
		t.Fatalf("config not created: %v", err)
	}
	if !strings.HasPrefix(string(body), sshBlockStart) {
		t.Errorf("expected the block at the top of a fresh file:\n%s", body)
	}
}

func TestRenderSSHBlockOmitsUserWhenUnknown(t *testing.T) {
	if got := renderSSHBlock("", testHosts()); strings.Contains(got, "User ") {
		t.Errorf("rendered a User line with no user:\n%s", got)
	}
}
