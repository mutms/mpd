package srv

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
)

// insideVolume is the only thing standing between a mis-composed path and
// `rm -rf` as root, so its refusals matter more than its acceptances.
func TestInsideVolumeRefusesPathsOutsideTheVolume(t *testing.T) {
	for _, path := range []string{
		"/", "/etc", "/home/skodak", "/var/lib/mpd",
		"srv/projects/x",  // relative: not the volume, whatever it looks like
		"/srvsomething/x", // prefix match without the separator
		"/srv/../etc",     // climbs out once cleaned
		"/srv/projects/../../etc",
	} {
		if _, err := insideVolume(path); err == nil {
			t.Errorf("insideVolume(%q) allowed a path outside %s", path, Dir)
		}
	}
}

// The volume root itself must be refused: emptying it would remove every
// project, database and backup on the VM.
func TestInsideVolumeRefusesTheVolumeRoot(t *testing.T) {
	for _, path := range []string{Dir, Dir + "/", Dir + "/."} {
		if _, err := insideVolume(path); err == nil {
			t.Errorf("insideVolume(%q) allowed the volume root", path)
		}
	}
}

func TestInsideVolumeAllowsProjectPaths(t *testing.T) {
	for _, path := range []string{
		ProjectDir("moodle45"),
		DataDir("moodle45"),
		MetaDir("moodle45"),
		Dir + "/dbs/postgres-17",
	} {
		clean, err := insideVolume(path)
		if err != nil {
			t.Errorf("insideVolume(%q) refused a legitimate path: %v", path, err)
		}
		if clean != filepath.Clean(path) {
			t.Errorf("insideVolume(%q) = %q, want the cleaned path", path, clean)
		}
	}
}

// A missing directory is already empty, so this must not be an error — and
// must not shell out to rm either.
func TestRemoveContentsOnMissingDirIsNoOp(t *testing.T) {
	if err := RemoveContents(context.Background(), Dir+"/data/definitely-not-here"); err != nil {
		t.Errorf("RemoveContents on a missing directory: %v", err)
	}
}

// The refusal has to happen before anything is executed, so a bad path
// returns an error rather than running rm as root.
func TestRemoveContentsRefusesOutsideVolume(t *testing.T) {
	err := RemoveContents(context.Background(), "/etc")
	if err == nil {
		t.Fatal("RemoveContents(/etc) should be refused")
	}
	if !strings.Contains(err.Error(), "outside") {
		t.Errorf("error should say why, got: %v", err)
	}
}

func TestDataDir(t *testing.T) {
	if got, want := DataDir("moodle45"), "/srv/data/moodle45"; got != want {
		t.Errorf("DataDir = %q, want %q", got, want)
	}
}
