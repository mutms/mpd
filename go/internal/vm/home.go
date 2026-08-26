package vm

import (
	"io"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/mutms/mpd/go/internal/ui"
)

// EnsureHome seeds the dev user's home from assets/vm/home — dotfiles the
// developer overlays through mpd-virt's asset tree (a ~/.vimrc, a
// ~/.ssh/known_hosts, whatever). It is not a fresh-account seed: the VM's dev
// account already exists at adoption, so this overlays onto the live home
// rather than populating a new one — which is why the VM cannot reuse the
// runtime's copy-at-create path and needs this step instead.
//
// Seed-once, per file: a file that already exists is left untouched — it is
// the developer's once present, like the old ~/.vimrc seed. So an edit made in
// the VM survives, and re-overlaying an updated file on the Mac does not
// clobber the in-VM copy (delete the in-VM file to re-seed). Parent
// directories are created as needed; an existing one (e.g. ~/.ssh) keeps its
// mode.
//
// mpd ships nothing here — assets/vm/home exists only once a developer overlays
// into it — so an absent directory is the normal "no overlay" case and a
// silent success. Best-effort: a per-file failure warns and continues.
func EnsureHome(out io.Writer) error {
	root := AssetsDir + "/vm/home"
	if info, err := os.Stat(root); err != nil || !info.IsDir() {
		ui.OK(out, "No developer home overlay (assets/vm/home absent).")
		return nil
	}

	home := Home()
	seeded := 0
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil || d.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return nil
		}
		dest := filepath.Join(home, rel)
		if _, err := os.Stat(dest); err == nil {
			return nil // seed-once: the file is the developer's once present
		}
		if err := seedFile(path, dest); err != nil {
			ui.Warn(out, "home file %s: %v", rel, err)
			return nil
		}
		seeded++
		return nil
	})
	if err != nil {
		return err
	}

	if seeded == 0 {
		ui.OK(out, "Developer home files already in place.")
	} else {
		ui.OK(out, "Seeded %d developer home file(s) from assets/vm/home.", seeded)
	}
	return nil
}

// seedFile copies src to dest, creating parent directories, preserving the
// source file's permission bits (so a mode-0600 overlay stays 0600).
func seedFile(src, dest string) error {
	info, err := os.Stat(src)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dest, data, info.Mode().Perm())
}
