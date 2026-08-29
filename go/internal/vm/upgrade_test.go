package vm

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mutms/mpd/go/internal/exec"
)

// gitRepo builds a throwaway checkout with the given origin.
// Deliberately no commit: committing drags in the developer's git
// identity, and SSH commit signing then blocks on an agent.
func gitRepo(t *testing.T, origin string) string {
	t.Helper()
	dir := t.TempDir()
	for _, args := range [][]string{
		{"init", "-q", "-b", "main"},
		{"remote", "add", "origin", origin},
	} {
		if code, err := exec.Run(ctx0(), exec.Cmd{Name: "git", Dir: dir, Args: args}); err != nil || code != 0 {
			t.Skipf("git unavailable or refused %v: %v", args, err)
		}
	}
	return dir
}

// dirty makes a checkout unclean; an untracked file is enough for
// GitClean.
func dirty(t *testing.T, dir string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, "scratch"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

const testRemote = "https://github.com/mutms/mudev.git"

// mpd's own clone, untouched, is mpd's to move.
func TestSkipReasonAllowsMpdsOwnCleanCheckout(t *testing.T) {
	repo := Repo{Dir: gitRepo(t, testRemote), Remote: testRemote}
	if reason := repo.SkipReason(); reason != "" {
		t.Errorf("mpd's own clean checkout was skipped: %s", reason)
	}
}

// A checkout re-pointed at the developer's own remote is theirs; origin
// decides ownership.
func TestSkipReasonLeavesADevelopersOwnRemoteAlone(t *testing.T) {
	repo := Repo{Dir: gitRepo(t, "git@github.com:mutms/mudev.git"), Remote: testRemote}
	reason := repo.SkipReason()
	if reason == "" {
		t.Fatal("a checkout on the developer's own remote was treated as mpd's")
	}
	if !strings.Contains(reason, "your own checkout") {
		t.Errorf("reason does not explain whose it is: %s", reason)
	}
}

// Uncommitted work outranks ownership: even mpd's own clone is left
// alone once edited.
func TestSkipReasonLeavesADirtyCheckoutAlone(t *testing.T) {
	dir := gitRepo(t, testRemote)
	dirty(t, dir)
	repo := Repo{Dir: dir, Remote: testRemote}
	if reason := repo.SkipReason(); !strings.Contains(reason, "uncommitted") {
		t.Errorf("dirty checkout not reported as such: %q", reason)
	}
}

// A missing directory is normal: an upgrade running before --vm-setup
// must not fail on its absence.
func TestSkipReasonHandlesAMissingCheckout(t *testing.T) {
	repo := Repo{Dir: filepath.Join(t.TempDir(), "absent"), Remote: testRemote}
	if reason := repo.SkipReason(); !strings.Contains(reason, "not a git checkout") {
		t.Errorf("missing directory not reported as such: %q", reason)
	}
}

// GitClean underpins every decision above, so it is pinned directly.
func TestGitCleanReadsTheCheckout(t *testing.T) {
	dir := gitRepo(t, testRemote)
	if !GitClean(dir) {
		t.Error("an untouched checkout reported dirty")
	}
	dirty(t, dir)
	if GitClean(dir) {
		t.Error("a checkout with an untracked file reported clean")
	}
}

// GitRev must answer "" on a checkout with no commits; a half-initialised
// tree must not crash the upgrade summary.
func TestGitRevIsEmptyWithoutCommits(t *testing.T) {
	if rev := GitRev(gitRepo(t, testRemote)); rev != "" {
		t.Errorf("GitRev on a commitless checkout = %q, want empty", rev)
	}
}
