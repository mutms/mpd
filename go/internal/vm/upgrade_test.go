package vm

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mutms/mpd/go/internal/exec"
)

// gitRepo builds a throwaway checkout with the given origin.
//
// Deliberately makes no commit. Committing drags in the developer's own
// git identity, and on this VM that means SSH commit signing: `git
// commit` blocks on ssh-keygen waiting for an agent, which a unit test
// has no business needing. Everything under test — is it a checkout, what
// is its origin, is it dirty — is observable without one.
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

// dirty makes a checkout unclean. An untracked file is enough: `git
// status --porcelain` reports it, which is what GitClean reads.
func dirty(t *testing.T, dir string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, "scratch"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

const testRemote = "https://github.com/mutms/mudev.git"

// The ordinary case: mpd's own clone, untouched, is mpd's to move.
func TestSkipReasonAllowsMpdsOwnCleanCheckout(t *testing.T) {
	repo := Repo{Dir: gitRepo(t, testRemote), Remote: testRemote}
	if reason := repo.SkipReason(); reason != "" {
		t.Errorf("mpd's own clean checkout was skipped: %s", reason)
	}
}

// The case that matters most: a developer who re-pointed the checkout at
// their own remote is working there. Pulling would drag their tree
// forward under them, which is why origin decides ownership.
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

// Uncommitted work outranks ownership: even mpd's own clone is left alone
// once someone has edited it, because --ff-only would fail anyway and the
// useful thing is to say why.
func TestSkipReasonLeavesADirtyCheckoutAlone(t *testing.T) {
	dir := gitRepo(t, testRemote)
	dirty(t, dir)
	repo := Repo{Dir: dir, Remote: testRemote}
	if reason := repo.SkipReason(); !strings.Contains(reason, "uncommitted") {
		t.Errorf("dirty checkout not reported as such: %q", reason)
	}
}

// A missing directory is normal, not an error: --vm-setup creates these,
// and an upgrade running before it must not fail on their absence.
func TestSkipReasonHandlesAMissingCheckout(t *testing.T) {
	repo := Repo{Dir: filepath.Join(t.TempDir(), "absent"), Remote: testRemote}
	if reason := repo.SkipReason(); !strings.Contains(reason, "not a git checkout") {
		t.Errorf("missing directory not reported as such: %q", reason)
	}
}

// GitClean underpins every decision above, so it is pinned directly
// rather than only through SkipReason.
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

// GitRev must answer "" rather than fail on a checkout with no commits —
// the upgrade prints it, and a half-initialised tree must not crash the
// summary line.
func TestGitRevIsEmptyWithoutCommits(t *testing.T) {
	if rev := GitRev(gitRepo(t, testRemote)); rev != "" {
		t.Errorf("GitRev on a commitless checkout = %q, want empty", rev)
	}
}
