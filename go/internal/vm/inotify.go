package vm

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/ui"
)

const inotifySysctl = "/etc/sysctl.d/99-mpd-inotify.conf"

// RaiseInotifyLimits lifts the per-user inotify watch limit to the
// value JetBrains recommends. An IDE backend watching a Moodle-sized
// tree exhausts the Debian default and silently stops seeing external
// file changes.
func RaiseInotifyLimits(ctx context.Context, out io.Writer) error {
	changed, err := WriteRootOwnedFile(ctx, inotifySysctl, "fs.inotify.max_user_watches = 1048576\n")
	if err != nil {
		return err
	}
	if code, err := exec.Run(ctx, exec.Cmd{Name: "bash", Args: []string{"-c", "sudo sysctl -q -w fs.inotify.max_user_watches=1048576"}}); err != nil || code != 0 {
		return fmt.Errorf("setting fs.inotify.max_user_watches failed")
	}
	if changed {
		ui.OK(out, "inotify watch limit raised (%s).", inotifySysctl)
	}
	return nil
}
