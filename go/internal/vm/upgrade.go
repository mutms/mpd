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

// SkipReason explains why a checkout was left alone, or "" when it can
// be updated. Reported rather than fixed: each case is the developer's
// own work or decision.
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
// --porcelain is stable across git versions and locales.
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

// GitCommitsBetween counts commits in old..new for the upgrade summary.
// Zero on any error: it is decoration.
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

// GitPullFastForward advances a checkout, refusing anything that is not
// a fast-forward. With the clean-tree check in SkipReason, an upgrade
// either advances the checkout or changes nothing at all.
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

// MakeInstall builds a checkout with its own Makefile. GOTOOLCHAIN=auto
// is set explicitly, not left to the default: the go.mod directive picks
// the compiler and /usr/local/go is only a seed, so an upgrade that
// raises the directive must be able to fetch the toolchain it names.
func MakeInstall(ctx context.Context, dir string) error {
	code, err := exec.Run(ctx, exec.Cmd{
		Name: "make", Args: []string{"-C", dir, "install"},
		Env: []string{"GOTOOLCHAIN=auto"},
	})
	if err != nil || code != 0 {
		return fmt.Errorf("make install failed in %s.", dir)
	}
	return nil
}

// ctx0 serves the short read-only git queries, which need no
// cancellation.
func ctx0() context.Context { return context.Background() }
