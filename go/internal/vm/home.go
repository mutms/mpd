package vm

import (
	"io"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/mutms/mpd/go/internal/ui"
)

// EnsureHome applies the developer's home overlay (assets/vm/home) onto
// the dev user's home. default/ files are seeded only when absent, so
// in-VM edits survive; forced/ files are overwritten on every run. It
// never deletes, so a removed source file cannot lose data. An absent
// tree is the normal "no overlay" case; per-file failures warn and
// continue. See AGENTS.md on assets/vm.
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

// applyHomeDir copies every file under root into home. overwrite=false
// seeds; overwrite=true replaces. It never removes anything; an absent
// root is a no-op. Returns the number of files written.
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
				return nil // seed-once: the file is the developer's
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

// seedFile copies src to dest, creating parents and preserving the
// source's permission bits, so a 0600 overlay stays 0600.
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
