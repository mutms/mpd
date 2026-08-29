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

// MudevDir is the mudev source tree on the VM. A build artefact: delete
// it and the next `--vm-setup` reproduces it from a public remote.
const MudevDir = "/opt/mudev"

// mudevRemote and catalogueRemotes are cloned over anonymous HTTPS,
// never SSH: `--vm-setup` must work on a fresh VM before any key or
// agent forwarding exists.
const mudevRemote = "https://github.com/mutms/mudev.git"

var catalogueRemotes = map[string]string{
	"mdl-plugins": "https://github.com/mutms/mdl-plugins.git",
	"mdl-recipes": "https://github.com/mutms/mdl-recipes.git",
}

// MudevRemote is the remote mpd itself clones, so the upgrade path can
// tell mpd's checkouts from the developer's.
func MudevRemote() string { return mudevRemote }

// CatalogueRemotes returns a copy of the catalogue remotes, so a caller
// cannot edit the source of truth.
func CatalogueRemotes() map[string]string {
	out := make(map[string]string, len(catalogueRemotes))
	for k, v := range catalogueRemotes {
		out[k] = v
	}
	return out
}

// EnsureMudev clones and builds mudev and clones the public catalogues
// into /srv/extra. Idempotent: an existing checkout is left alone, so
// local branches and uncommitted work survive `--vm-setup`.
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
// clones into it. sudo only for the mkdir: the checkout itself must stay
// unprivileged and developer-owned.
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
// into ~/.local/bin. GOTOOLCHAIN=local: Go's default would silently
// download a large toolchain when go.mod asks for a newer version than
// Debian ships.
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

// ensureCatalogues clones the public catalogues into /srv/extra. The
// private dev-recipes catalogue is deliberately absent: the developer
// clones that themselves.
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
		// --progress: without it a large clone to a non-terminal looks
		// frozen.
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
