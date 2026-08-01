package vm

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/ui"
)

// procSysUnitName is the system unit that keeps /proc/sys writable for
// podman. --vm-setup installs it once; it then fires on every boot.
const procSysUnitName = "mpd-proc-sys-rw.service"

// ProcSysUnit remounts /proc/sys read-write early at boot.
//
// An Apple container starts with /proc/sys mounted read-only, but podman's
// netavark writes bridge sysctls and crun writes net.ipv4.ping_group_range
// there — so every podman service that comes up at boot (the restart of the
// service containers, caddy binding the bridge gateway) fails before mpd can
// intervene. Remounting inline in --vm-setup would fix only the setup run;
// this unit fixes every boot, which is the reason it is a unit and not a
// step.
//
// ConditionPathIsReadWrite=!/proc/sys makes it a genuine no-op on a real VM,
// where /proc/sys is already writable: the condition is unmet, systemd skips
// the unit, and one code path serves both worlds. DefaultDependencies=no with
// Before=sysinit.target lands it ahead of podman.socket and the service units
// while /proc itself is already mounted.
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

// EnsureProcSysWritable installs the remount unit and applies it now, so the
// current --vm-setup run and every future boot both find /proc/sys writable.
//
// Idempotent: an unchanged unit is not rewritten, and `enable --now` on a
// unit already active (or whose condition is unmet, as on a VM) is a no-op.
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
