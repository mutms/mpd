package vm

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/ui"
)

// SrvMountUnit renders the unit that makes the data volume visible at
// /srv. The unit MUST be named srv.mount: systemd derives a mount unit's
// name from its mount point.
//
// A bind mount, not a symlink: podman's volume store is 0700 root, so
// the dev user cannot traverse into it. source is podman's mountpoint,
// read at setup time. ConditionPathIsDirectory keeps a VM whose volume
// was removed from failing at boot. nofail with a short device timeout:
// in a udev-less container the auto-added dev-*.device dependency never
// appears and would fail the mount job after 90s.
func SrvMountUnit(source string) string {
	return fmt.Sprintf(`[Unit]
Description=mpd data volume at /srv
ConditionPathIsDirectory=%s

[Mount]
What=%s
Where=/srv
Type=none
Options=bind,nofail,x-systemd.device-timeout=2s

[Install]
WantedBy=multi-user.target
`, source, source)
}

// MountDataVolume installs and activates srv.mount. Idempotent; a
// changed unit is restarted so a moved volume is followed. Success is
// judged by `is-active`, not systemctl's exit code — in a udev-less
// container the phantom device dependency fails while the mount is up.
func MountDataVolume(ctx context.Context, out io.Writer, source string) error {
	if source == "" {
		return fmt.Errorf("Cannot mount /srv: podman reported no mountpoint for the data volume.")
	}

	const unitPath = "/etc/systemd/system/srv.mount"
	changed, err := WriteRootOwnedFile(ctx, unitPath, SrvMountUnit(source))
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

	// `enable` starts nothing, so it never triggers the phantom device
	// job and its exit is trustworthy.
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "systemctl", Args: []string{"enable", "srv.mount"}, Sudo: true,
	}); err != nil || code != 0 {
		return fmt.Errorf("Failed to enable srv.mount (source %s).", source)
	}

	// The exit code is deliberately ignored: in a udev-less container the
	// phantom device dependency makes systemctl exit non-zero even though
	// the mount is up. is-active below is the success signal.
	verb := "start"
	if changed {
		verb = "restart"
	}
	if _, err := exec.Run(ctx, exec.Cmd{
		Name: "systemctl", Args: []string{verb, "srv.mount"}, Sudo: true,
	}); err != nil {
		return err
	}
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "systemctl", Args: []string{"is-active", "--quiet", "srv.mount"},
	}); err != nil || code != 0 {
		return fmt.Errorf("srv.mount did not come up (source %s).", source)
	}

	ui.OK(out, "/srv mounted from %s.", source)
	return nil
}
