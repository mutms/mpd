package vm

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/ui"
)

const printkSysctl = "/etc/sysctl.d/99-mpd-printk.conf"

// QuietConsole keeps the kernel console to warnings and errors. The cloud
// image boots without `quiet`, so at the default console loglevel every
// AppArmor profile load and audit line scrolls over the VM console.
// Everything still reaches the journal.
func QuietConsole(ctx context.Context, out io.Writer) error {
	changed, err := WriteRootOwnedFile(ctx, printkSysctl, "kernel.printk = 4 4 1 7\n")
	if err != nil {
		return err
	}
	if code, err := exec.Run(ctx, exec.Cmd{Name: "bash", Args: []string{"-c", "sudo sysctl -q -w 'kernel.printk=4 4 1 7'"}}); err != nil || code != 0 {
		return fmt.Errorf("setting kernel.printk failed")
	}
	if changed {
		ui.OK(out, "kernel console quieted (%s).", printkSysctl)
	}
	return nil
}
