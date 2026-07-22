package cli

import (
	"context"
	"fmt"
	"io"
	"path/filepath"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/ui"
	"github.com/mutms/mpd/go/internal/vm"
)

// Upgrade moves the VM's mpd install forward: pull, build, apply.
//
// The third step is the reason this verb exists. `git pull && make
// install` looks like the whole job and is not: asset scripts, systemd
// units, the resolver's config and the podman network's properties only
// reach the VM through `--vm-setup`. Skipping it leaves a VM running a new
// binary against old plumbing, which is how two VMs ended up with a
// resolver at an address nothing listened on.
//
// mudev and the /srv/extra catalogues come along because mpd clones and
// builds them itself — but only when they are still mpd's clones. A
// checkout the developer re-pointed at their own remote is theirs, and
// gets reported rather than pulled.
func Upgrade(ctx context.Context, out io.Writer) error {
	fmt.Fprintf(out, "\n\033[1mmpd --vm-upgrade\033[0m\n\n")

	// mpd first and on its own: it gates everything after it, and unlike
	// the others a stale or dirty checkout here means there is nothing to
	// build.
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

	// Apply, by running the binary we just built rather than calling
	// Setup in-process: this process is the OLD mpd, and its idea of what
	// setup does is exactly what the upgrade replaced.
	fmt.Fprintf(out, "\n\033[1m==> Applying: %s --vm-setup\033[0m\n", vm.BinaryPath)
	if code, err := exec.Run(ctx, exec.Cmd{Name: "mpd", Args: []string{"--vm-setup"}}); err != nil || code != 0 {
		return fmt.Errorf("`%s --vm-setup` failed after upgrading. The new binary is built; re-run it to see why.",
			vm.BinaryPath)
	}

	if !upgraded {
		fmt.Fprintf(out, "\n\033[1;32m✓ Already up to date.\033[0m\n")
		return nil
	}
	fmt.Fprintf(out, "\n\033[1;32m✓ mpd upgraded.\033[0m\n")
	return nil
}

// upgradeMpd advances and rebuilds mpd's own checkout, reporting whether
// anything moved. Refuses rather than works around: this is the tree mpd
// is developed in, and today it may well hold work in progress.
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
		// Built anyway: the checkout can be current while bin/mpd is not,
		// after an interrupted upgrade or an edit that was reverted.
		return false, vm.MakeInstall(ctx, vm.MpdDir)
	}
	ui.OK(out, "%s → %s (%d commits).", before, after, vm.GitCommitsBetween(vm.MpdDir, before, after))
	if err := vm.MakeInstall(ctx, vm.MpdDir); err != nil {
		return false, err
	}
	ui.OK(out, "Rebuilt %s.", vm.BinaryPath)
	return true, nil
}

// upgradeCompanion advances one of the checkouts mpd provisions.
//
// Never fatal. These are conveniences beside the mpd upgrade itself, and
// a private recipe catalogue that cannot be reached is not a reason to
// abandon a binary that already built. build says whether the checkout
// has a Makefile worth running.
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
