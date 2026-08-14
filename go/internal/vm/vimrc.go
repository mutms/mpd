package vm

import (
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/mutms/mpd/go/internal/ui"
)

// EnsureVimrc seeds the dev user's ~/.vimrc from assets/vm/vimrc, so vim
// on the VM starts with mouse reporting off and terminal selection can
// copy out of a file again.
//
// Seeded, not managed: an existing ~/.vimrc is left alone. Unlike the
// ~/.bashrc block, there is no marker to write inside — the whole file
// is the developer's once it exists.
//
// The runtime container gets the same two lines from
// assets/runtime/skel/.vimrc, copied into the home directory at
// container create.
func EnsureVimrc(out io.Writer) error {
	source := AssetsDir + "/vm/vimrc"
	body, err := os.ReadFile(source)
	if err != nil {
		return fmt.Errorf("vimrc asset missing: %s", source)
	}
	path := filepath.Join(Home(), ".vimrc")
	if _, err := os.Stat(path); err == nil {
		ui.OK(out, "~/.vimrc exists — left as it is.")
		return nil
	}
	if err := os.WriteFile(path, body, 0o644); err != nil {
		return fmt.Errorf("Failed to write %s: %w", path, err)
	}
	ui.OK(out, "~/.vimrc seeded (mouse off, so selection copies).")
	return nil
}
