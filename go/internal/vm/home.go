package vm

import (
	"io"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/mutms/mpd/go/internal/ui"
)

// EnsureHome applies the developer's home overlay onto the VM dev user's home.
// The files come from mpd-virt's asset tree (assets/vm/home), in two flavours:
//
//   - assets/vm/home/default/ — SEEDED: copied only when the file does not yet
//     exist. It is the developer's once present, so an edit made in the VM
//     survives and re-overlaying does not clobber it. For dotfiles you tweak
//     (a ~/.vimrc, a ~/.ssh/known_hosts you append to).
//
//   - assets/vm/home/forced/ — OVERWRITTEN from the Mac on every run, so a Mac
//     edit propagates. mpd owns these; edit them on the Mac, not in the VM. For
//     settings you want kept in step (a ~/.gitconfig, forced tool configs).
//
// It NEVER deletes: a file removed from forced/ on the Mac is left in place in
// the home, so this can never lose data — the deliberate trade for the
// overwrite behaviour.
//
// This is not a fresh-account seed: the VM's dev account already exists at
// adoption, so this overlays onto the live home (the reason the VM can't reuse
// the runtime's copy-at-create path). mpd ships nothing here — the directories
// exist only once a developer overlays into them — so an absent tree is the
// normal "no overlay" case. Best-effort: a per-file failure warns and continues.
func EnsureHome(out io.Writer) error {
	base := AssetsDir + "/vm/home"
	home := Home()

	seeded, err := applyHomeDir(out, base+"/default", home, false)
	if err != nil {
		return err
	}
	forced, err := applyHomeDir(out, base+"/forced", home, true)
	if err != nil {
		return err
	}

	switch {
	case seeded == 0 && forced == 0:
		ui.OK(out, "No developer home overlay (assets/vm/home).")
	default:
		ui.OK(out, "Developer home: %d seeded, %d forced.", seeded, forced)
	}
	return nil
}

// applyHomeDir copies every file under root into home, preserving the relative
// path. overwrite=false seeds (an existing destination is left untouched);
// overwrite=true refreshes (an existing destination is replaced). It NEVER
// removes anything — a file gone from root stays in the home. An absent root is
// a no-op. Returns the number of files written. Best-effort per file.
func applyHomeDir(out io.Writer, root, home string, overwrite bool) (int, error) {
	if info, err := os.Stat(root); err != nil || !info.IsDir() {
		return 0, nil
	}
	written := 0
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil || d.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return nil
		}
		dest := filepath.Join(home, rel)
		if !overwrite {
			if _, err := os.Stat(dest); err == nil {
				return nil // seed-once: the file is the developer's once present
			}
		}
		if err := seedFile(path, dest); err != nil {
			ui.Warn(out, "home file %s: %v", rel, err)
			return nil
		}
		written++
		return nil
	})
	return written, err
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
