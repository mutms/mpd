package vm

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/ui"
)

// procSysUnitName is the system unit that keeps /proc/sys writable for
// podman on every boot.
const procSysUnitName = "mpd-proc-sys-rw.service"

// ProcSysUnit remounts /proc/sys read-write early at boot.
//
// An Apple container starts with /proc/sys read-only, but netavark and
// crun write sysctls there, so podman services fail at boot. A unit
// rather than a setup step, so every boot is fixed.
// ConditionPathIsReadWrite=!/proc/sys makes it a no-op on a real VM.
func ProcSysUnit() string {
	return `[Unit]
Description=Remount /proc/sys read-write for podman
DefaultDependencies=no
ConditionPathIsReadWrite=!/proc/sys
After=systemd-remount-fs.service
Before=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/mount -o remount,rw /proc/sys

[Install]
WantedBy=sysinit.target
`
}

// EnsureProcSysWritable installs the remount unit and applies it now.
// Idempotent.
func EnsureProcSysWritable(ctx context.Context, out io.Writer) error {
	ui.Step(out, "Writable /proc/sys for podman")

	const unitPath = "/etc/systemd/system/" + procSysUnitName
	changed, err := WriteRootOwnedFile(ctx, unitPath, ProcSysUnit())
	if err != nil {
		return err
	}
	if changed {
		if code, err := exec.Run(ctx, exec.Cmd{
			Name: "systemctl", Args: []string{"daemon-reload"}, Sudo: true,
		}); err != nil || code != 0 {
			return fmt.Errorf("systemctl daemon-reload failed after writing %s.", unitPath)
		}
	}
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "systemctl", Args: []string{"enable", "--now", procSysUnitName}, Sudo: true,
	}); err != nil || code != 0 {
		return fmt.Errorf("Failed to enable %s.", procSysUnitName)
	}
	ui.OK(out, "%s installed and applied.", procSysUnitName)
	return nil
}
