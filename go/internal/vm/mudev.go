package vm

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/ui"
)

// MudevDir is the mudev source tree on the VM. A build artefact, not
// content: delete it and the next `--vm-setup` reproduces it from a
// public remote, which is why it lives beside the other /opt checkouts
// rather than on the data volume.
const MudevDir = "/opt/mudev"

// mudevRemote and catalogueRemotes are cloned over anonymous HTTPS.
//
// Never SSH: `--vm-setup` has to work on a fresh VM before the developer
// has arranged agent forwarding or dropped a key, so every remote it
// touches is public. Push access is the developer's own one-off
// `git remote set-url`, and the private dev-recipes catalogue is a clone
// they make themselves into /srv/extra, which is theirs to write.
const mudevRemote = "https://github.com/mutms/mudev.git"

var catalogueRemotes = map[string]string{
	"mdl-plugins": "https://github.com/mutms/mdl-plugins.git",
	"mdl-recipes": "https://github.com/mutms/mdl-recipes.git",
}

// MudevRemote and CatalogueRemotes expose what mpd itself clones, so the
// upgrade path can tell its own checkouts from the developer's. A
// checkout whose origin differs is not mpd's to move.
func MudevRemote() string { return mudevRemote }

// CatalogueRemotes returns a copy, so a caller iterating it cannot edit
// the source of truth.
func CatalogueRemotes() map[string]string {
	out := make(map[string]string, len(catalogueRemotes))
	for k, v := range catalogueRemotes {
		out[k] = v
	}
	return out
}

// EnsureMudev clones and builds mudev, and clones the public catalogues
// it reads into /srv/extra.
//
// Available before any runtime exists, which is the point: mudev
// assembles a Moodle tree from a recipe, and that is work you do while
// setting a project up, not something to install into a php runtime
// afterwards.
//
// Idempotent. An existing checkout is left as it is — mpd provisions
// mudev, it does not manage the developer's working copy, so a local
// branch or uncommitted work survives `--vm-setup`. Updating is a `git
// pull` plus `make install`.
func EnsureMudev(ctx context.Context, out io.Writer) error {
	if err := ensureMudevCheckout(ctx, out); err != nil {
		return err
	}
	if err := buildMudev(ctx, out); err != nil {
		return err
	}
	return ensureCatalogues(ctx, out)
}

// ensureMudevCheckout creates /opt/mudev owned by the dev user, then
// clones into it. sudo only for the mkdir: /opt is root-owned, and
// everything after this point — clone, build, rebuild — must be
// unprivileged so the developer owns their own checkout.
func ensureMudevCheckout(ctx context.Context, out io.Writer) error {
	if isGitCheckout(MudevDir) {
		ui.OK(out, "mudev checkout present at %s.", MudevDir)
		return nil
	}
	id := DetectIdentity()
	if id.UID == "" {
		return fmt.Errorf("cannot create %s: no dev user identity", MudevDir)
	}
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "install",
		Args: []string{"-d", "-o", id.UID, "-g", id.UID, "-m", "0755", MudevDir},
		Sudo: true,
	}); err != nil || code != 0 {
		return fmt.Errorf("Failed to create %s.", MudevDir)
	}
	if err := cloneInto(ctx, out, mudevRemote, MudevDir); err != nil {
		return err
	}
	ui.OK(out, "Cloned mudev into %s.", MudevDir)
	return nil
}

// buildMudev runs `make install`, which builds bin/mudev and symlinks it
// into ~/.local/bin.
//
// GOTOOLCHAIN=local for the same reason mpd's own Makefile sets it:
// Go's default would silently download a ~210 MB toolchain when a
// go.mod asks for a newer version than Debian ships. Failing loudly is
// the better outcome.
func buildMudev(ctx context.Context, out io.Writer) error {
	code, err := exec.Run(ctx, exec.Cmd{
		Name: "make",
		Args: []string{"-C", MudevDir, "install"},
		Env:  []string{"GOTOOLCHAIN=local"},
	})
	if err != nil || code != 0 {
		return fmt.Errorf("Failed to build mudev in %s (make install).", MudevDir)
	}
	ui.OK(out, "mudev built and linked into ~/.local/bin.")
	return nil
}

// ensureCatalogues clones the public plugin and recipe catalogues into
// /srv/extra, which mudev reads by default.
//
// Only the public ones. dev-recipes is private and deliberately absent:
// /srv/extra is dev-user-owned, so cloning it is one ordinary `git
// clone` by whoever has access, with nothing for mpd to prepare.
func ensureCatalogues(ctx context.Context, out io.Writer) error {
	for _, name := range sortedNames(catalogueRemotes) {
		dir := filepath.Join(srv.Extra, name)
		if isGitCheckout(dir) {
			ui.OK(out, "%s already cloned.", name)
			continue
		}
		if entries, err := os.ReadDir(dir); err == nil && len(entries) > 0 {
			return fmt.Errorf("%s is not empty but is not a git checkout — move it aside and re-run.", dir)
		}
		if err := cloneInto(ctx, out, catalogueRemotes[name], dir); err != nil {
			return err
		}
		ui.OK(out, "Cloned %s into %s.", name, dir)
	}
	return nil
}

func cloneInto(ctx context.Context, out io.Writer, remote, dir string) error {
	ui.Step(out, "Cloning %s", remote)
	code, err := exec.Run(ctx, exec.Cmd{
		Name: "git",
		// --progress: git's isatty check can misfire when its output is
		// not a terminal, leaving a large clone apparently frozen.
		Args: []string{"clone", "--progress", remote, dir},
	})
	if err != nil || code != 0 {
		return fmt.Errorf("Failed to clone %s into %s.", remote, dir)
	}
	return nil
}

func isGitCheckout(dir string) bool {
	info, err := os.Stat(filepath.Join(dir, ".git"))
	return err == nil && info.IsDir()
}

func sortedNames(m map[string]string) []string {
	names := make([]string, 0, len(m))
	for k := range m {
		names = append(names, k)
	}
	sort.Strings(names)
	return names
}
