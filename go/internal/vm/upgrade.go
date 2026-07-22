package vm

import (
	"context"
	"fmt"
	"strings"

	"github.com/mutms/mpd/go/internal/exec"
)

// Repo is one git checkout mpd knows how to move forward.
type Repo struct {
	// Dir is the checkout.
	Dir string
	// Remote is the URL mpd itself would clone. A checkout whose origin
	// differs is the developer's own, and mpd does not touch it.
	Remote string
}

// SkipReason explains why a checkout was left alone, or "" when it can be
// updated. Reported rather than fixed: every one of these describes work
// in progress or a decision the developer made, and overriding it would
// throw away exactly the thing they would miss.
func (r Repo) SkipReason() string {
	if !isGitCheckout(r.Dir) {
		return "not a git checkout"
	}
	if origin := GitRemote(r.Dir); origin != r.Remote {
		return fmt.Sprintf("origin is %s, not mpd's %s — your own checkout", origin, r.Remote)
	}
	if !GitClean(r.Dir) {
		return "uncommitted changes"
	}
	return ""
}

// GitRemote reads a checkout's origin URL, or "" if it has none.
func GitRemote(dir string) string {
	res, err := exec.Capture(ctx0(), exec.Cmd{
		Name: "git", Dir: dir, Args: []string{"remote", "get-url", "origin"},
	})
	if err != nil || res.Code != 0 {
		return ""
	}
	return strings.TrimSpace(res.Stdout)
}

// GitClean reports whether a checkout has no uncommitted changes.
//
// --porcelain rather than parsing `git status`: its output is a stable
// machine format, and empty means clean regardless of git's version or
// the user's locale.
func GitClean(dir string) bool {
	res, err := exec.Capture(ctx0(), exec.Cmd{
		Name: "git", Dir: dir, Args: []string{"status", "--porcelain"},
	})
	return err == nil && res.Code == 0 && strings.TrimSpace(res.Stdout) == ""
}

// GitRev is the short commit a checkout is on, or "" if it cannot be read.
func GitRev(dir string) string {
	res, err := exec.Capture(ctx0(), exec.Cmd{
		Name: "git", Dir: dir, Args: []string{"rev-parse", "--short", "HEAD"},
	})
	if err != nil || res.Code != 0 {
		return ""
	}
	return strings.TrimSpace(res.Stdout)
}

// GitCommitsBetween counts commits in old..new, for the "(N commits)" in
// the upgrade summary. Zero on any error — it is decoration, and failing
// an upgrade over a commit count would be absurd.
func GitCommitsBetween(dir, old, new string) int {
	if old == "" || new == "" || old == new {
		return 0
	}
	res, err := exec.Capture(ctx0(), exec.Cmd{
		Name: "git", Dir: dir, Args: []string{"rev-list", "--count", old + ".." + new},
	})
	if err != nil || res.Code != 0 {
		return 0
	}
	n := 0
	if _, err := fmt.Sscanf(strings.TrimSpace(res.Stdout), "%d", &n); err != nil {
		return 0
	}
	return n
}

// GitPullFastForward advances a checkout, refusing anything that is not a
// fast-forward.
//
// --ff-only is the whole safety model. A merge or a rebase here would
// rewrite work mpd did not create, in a directory the developer may be
// mid-thought in; refusing and saying so leaves them in control. Combined
// with the clean-tree check in SkipReason, an upgrade either advances the
// checkout or changes nothing at all.
func GitPullFastForward(ctx context.Context, dir string) error {
	code, err := exec.Run(ctx, exec.Cmd{
		Name: "git", Dir: dir, Args: []string{"pull", "--ff-only"},
	})
	if err != nil || code != 0 {
		return fmt.Errorf(`git pull --ff-only failed in %s.

The checkout cannot be fast-forwarded — local commits, a diverged branch,
or an unreachable remote. Sort it out there and re-run:

    cd %s && git status && git log --oneline -3`, dir, dir)
	}
	return nil
}

// MakeInstall builds a checkout with its own Makefile.
//
// GOTOOLCHAIN=local for the reason mpd's Makefile pins it: Go's default
// would silently download a ~210 MB toolchain when a go.mod asks for a
// newer version than Debian ships, on every VM, during what is supposed
// to be a quick upgrade.
func MakeInstall(ctx context.Context, dir string) error {
	code, err := exec.Run(ctx, exec.Cmd{
		Name: "make", Args: []string{"-C", dir, "install"},
		Env: []string{"GOTOOLCHAIN=local"},
	})
	if err != nil || code != 0 {
		return fmt.Errorf("make install failed in %s.", dir)
	}
	return nil
}

// ctx0 is for the short read-only git queries above, which have no
// cancellation story worth threading a context through for.
func ctx0() context.Context { return context.Background() }
