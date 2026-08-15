package project

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The shape a project type's template ships: a real setting, and optional
// keys as commented examples, each under the comment block explaining it.
const tmpl = `# mpd.env — settings for this project.

# Database
# Which engine and version to run.
MPD_DB=postgres:latest

# PHP version
# One of: 8.1 … 8.5.
#MPD_PHP_VERSION=8.4

# Behat
# Set to 1 to run Behat tests.
#MPD_MOODLE_BEHAT=1
`

// line reports the 1-based line number a prefix is found on, or 0.
func line(s, prefix string) int {
	for i, l := range strings.Split(s, "\n") {
		if strings.HasPrefix(l, prefix) {
			return i + 1
		}
	}
	return 0
}

// An existing setting is rewritten where it stands. This is the whole
// point of the file: move it and it lands under a comment about something
// else.
func TestExistingSettingKeepsItsPlace(t *testing.T) {
	before := line(tmpl, "MPD_DB=")
	got := string(setEnvKey([]byte(tmpl), "MPD_DB", "postgres:18"))
	if after := line(got, "MPD_DB="); after != before {
		t.Fatalf("MPD_DB moved from line %d to %d:\n%s", before, after, got)
	}
	if !strings.Contains(got, "MPD_DB=postgres:18\n") {
		t.Fatalf("value not written:\n%s", got)
	}
}

// A commented example becomes the setting, so the value lands under the
// comment block that describes it rather than at the end of the file.
func TestCommentedExampleIsTakenOver(t *testing.T) {
	at := line(tmpl, "#MPD_PHP_VERSION=")
	got := string(setEnvKey([]byte(tmpl), "MPD_PHP_VERSION", "8.5"))
	if l := line(got, "MPD_PHP_VERSION="); l != at {
		t.Fatalf("want the setting on line %d, got %d:\n%s", at, l, got)
	}
	if strings.Count(got, "MPD_PHP_VERSION") != 1 {
		t.Fatalf("example should have been replaced, not kept:\n%s", got)
	}
}

// Unsetting comments the line out, so a later set puts the value back in
// the same place. The round trip is the test.
func TestUnsetCommentsOutInPlace(t *testing.T) {
	at := line(tmpl, "MPD_DB=")

	unset := string(setEnvKey([]byte(tmpl), "MPD_DB", ""))
	if l := line(unset, "#MPD_DB=postgres:latest"); l != at {
		t.Fatalf("want it commented out on line %d, got %d:\n%s", at, l, unset)
	}
	if line(unset, "MPD_DB=") != 0 {
		t.Fatalf("key should no longer be set:\n%s", unset)
	}

	reset := string(setEnvKey([]byte(unset), "MPD_DB", "mariadb:11"))
	if l := line(reset, "MPD_DB=mariadb:11"); l != at {
		t.Fatalf("want it back on line %d, got %d:\n%s", at, l, reset)
	}
}

// Unsetting a key that only exists as an example leaves the file alone —
// there is nothing set to unset.
func TestUnsetLeavesACommentedExampleAlone(t *testing.T) {
	if got := string(setEnvKey([]byte(tmpl), "MPD_PHP_VERSION", "")); got != tmpl {
		t.Fatalf("file changed:\n%s", got)
	}
}

// A real setting wins over a commented example even when the example comes
// first, and duplicates below the kept line are dropped — the last one used
// to be the effective value, so leaving them would contradict the new one.
func TestSettingWinsOverExampleAndDuplicatesGo(t *testing.T) {
	in := "#MPD_DB=hint\nX=1\nMPD_DB=old\nfiller\nMPD_DB=dup\n"
	want := "#MPD_DB=hint\nX=1\nMPD_DB=new\nfiller\n"
	if got := string(setEnvKey([]byte(in), "MPD_DB", "new")); got != want {
		t.Fatalf("got:\n%q\nwant:\n%q", got, want)
	}
}

// A key the file has never mentioned goes at the end, one blank line clear.
func TestUnknownKeyIsAppended(t *testing.T) {
	got := string(setEnvKey([]byte(tmpl), "MPD_XDEBUG_MODE", "debug"))
	if !strings.HasSuffix(got, "#MPD_MOODLE_BEHAT=1\n\nMPD_XDEBUG_MODE=debug\n") {
		t.Fatalf("got:\n%s", got)
	}
}

// A file with no trailing newline must not end up with two settings on one
// line.
func TestFileWithoutTrailingNewline(t *testing.T) {
	got := string(setEnvKey([]byte("A=1"), "MPD_DB", "x"))
	if got != "A=1\n\nMPD_DB=x\n" {
		t.Fatalf("got: %q", got)
	}
}

// A near-miss key must not be touched: MPD_DB_HOST is not MPD_DB.
func TestPrefixOfAnotherKeyIsNotTouched(t *testing.T) {
	in := "MPD_DB_HOST=elsewhere\nMPD_DB=old\n"
	want := "MPD_DB_HOST=elsewhere\nMPD_DB=new\n"
	if got := string(setEnvKey([]byte(in), "MPD_DB", "new")); got != want {
		t.Fatalf("got: %q", got)
	}
}

// The file mode survives the rewrite. mktemp-and-rename defaults to 0600,
// which would leave a project's mpd.env unreadable to anything but its
// owner.
func TestSetEnvKeyKeepsFileMode(t *testing.T) {
	path := filepath.Join(t.TempDir(), "mpd.env")
	if err := os.WriteFile(path, []byte(tmpl), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := SetEnvKey(path, "MPD_DB", "postgres:18"); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o644 {
		t.Fatalf("mode is %o, want 644", got)
	}
}
