package cli

import (
	"context"
	"fmt"
	"io"
	"path/filepath"
	"strings"
	"time"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/ui"
	"github.com/mutms/mpd/go/internal/vm"
)

// Upgrade moves the VM's mpd install forward: pull, build, apply. The
// apply step is the point — systemd units, resolver config and network
// properties only reach the VM through `--vm-setup`, so `git pull &&
// make install` alone leaves new code on old plumbing. Companion
// checkouts come along only while they are still mpd's own clones.
func Upgrade(ctx context.Context, out io.Writer, s state.Store) error {
	fmt.Fprintf(out, "\n\033[1mmpd --vm-upgrade\033[0m\n\n")

	// mpd first: it gates everything after it.
	ui.Step(out, "mpd (%s)", vm.MpdDir)
	upgraded, err := upgradeMpd(ctx, out)
	if err != nil {
		return err
	}

	ui.Step(out, "mudev (%s)", vm.MudevDir)
	upgradeCompanion(ctx, out, vm.Repo{Dir: vm.MudevDir, Remote: vm.MudevRemote()}, true)

	ui.Step(out, "Catalogues in %s", srv.Extra)
	for name, remote := range vm.CatalogueRemotes() {
		upgradeCompanion(ctx, out, vm.Repo{Dir: filepath.Join(srv.Extra, name), Remote: remote}, false)
	}

	// Apply by running the freshly built binary, not Setup in-process:
	// this process is the old mpd.
	fmt.Fprintf(out, "\n\033[1m==> Applying: %s --vm-setup\033[0m\n", vm.BinaryPath)
	if code, err := exec.Run(ctx, exec.Cmd{Name: "mpd", Args: []string{"--vm-setup"}}); err != nil || code != 0 {
		return fmt.Errorf("`%s --vm-setup` failed after upgrading. The new binary is built; re-run it to see why.",
			vm.BinaryPath)
	}

	// The runtime is upgraded in place. Same new-binary rule as above.
	fmt.Fprintf(out, "\n\033[1m==> Applying: %s --runtime-upgrade\033[0m\n", vm.BinaryPath)
	if code, err := exec.Run(ctx, exec.Cmd{Name: "mpd", Args: []string{"--runtime-upgrade"}}); err != nil || code != 0 {
		return fmt.Errorf("`%s --runtime-upgrade` failed. The new binary is built; re-run it to see why.",
			vm.BinaryPath)
	}

	recordUpgrade(ctx, out, s)

	if !upgraded {
		fmt.Fprintf(out, "\n\033[1;32m✓ Already up to date.\033[0m\n")
		return nil
	}
	fmt.Fprintf(out, "\n\033[1;32m✓ mpd upgraded.\033[0m\n")
	return nil
}

// recordUpgrade stamps config.json for `mpd --vm-diag`. It asks the new
// binary for its version — this process is the old mpd. Never fatal:
// the upgrade already succeeded by the time this runs.
func recordUpgrade(ctx context.Context, out io.Writer, s state.Store) {
	res, err := exec.Capture(ctx, exec.Cmd{Name: "mpd", Args: []string{"--version"}})
	if err != nil || res.Failed() {
		ui.Warn(out, "could not read the new binary's version — upgrade not recorded")
		return
	}
	c := s.Config()
	c.LastUpgradeVersion = strings.TrimSpace(res.Stdout)
	c.LastUpgradeAt = time.Now().UTC().Format(time.RFC3339)
	if err := s.SaveConfig(c); err != nil {
		ui.Warn(out, "could not record the upgrade in config.json: %v", err)
	}
}

// upgradeMpd advances and rebuilds mpd's own checkout, reporting whether
// anything moved. A dirty tree refuses: it may hold work in progress.
func upgradeMpd(ctx context.Context, out io.Writer) (bool, error) {
	if !vm.GitClean(vm.MpdDir) {
		return false, fmt.Errorf(`%s has uncommitted changes.

mpd will not pull over work in progress. Commit, stash or discard it:

    cd %s && git status`, vm.MpdDir, vm.MpdDir)
	}
	before := vm.GitRev(vm.MpdDir)
	if err := vm.GitPullFastForward(ctx, vm.MpdDir); err != nil {
		return false, err
	}
	after := vm.GitRev(vm.MpdDir)

	if before == after {
		ui.OK(out, "already at %s.", after)
		// Build anyway: the checkout can be current while bin/mpd is not.
		return false, vm.MakeInstall(ctx, vm.MpdDir)
	}
	ui.OK(out, "%s → %s (%d commits).", before, after, vm.GitCommitsBetween(vm.MpdDir, before, after))
	if err := vm.MakeInstall(ctx, vm.MpdDir); err != nil {
		return false, err
	}
	ui.OK(out, "Rebuilt %s.", vm.BinaryPath)
	return true, nil
}

// upgradeCompanion advances one of the checkouts mpd provisions. Never
// fatal — an unreachable companion must not fail an upgrade that built.
// build says whether the checkout has a Makefile worth running.
func upgradeCompanion(ctx context.Context, out io.Writer, repo vm.Repo, build bool) {
	name := filepath.Base(repo.Dir)
	if reason := repo.SkipReason(); reason != "" {
		ui.OK(out, "%s left alone (%s).", name, reason)
		return
	}
	before := vm.GitRev(repo.Dir)
	if err := vm.GitPullFastForward(ctx, repo.Dir); err != nil {
		ui.Warn(out, "%s not updated: %v", name, err)
		return
	}
	after := vm.GitRev(repo.Dir)
	if before == after {
		ui.OK(out, "%s already at %s.", name, after)
		return
	}
	ui.OK(out, "%s %s → %s (%d commits).", name, before, after,
		vm.GitCommitsBetween(repo.Dir, before, after))
	if build {
		if err := vm.MakeInstall(ctx, repo.Dir); err != nil {
			ui.Warn(out, "%s pulled but did not build: %v", name, err)
		}
	}
}
