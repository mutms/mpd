package vm

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/ui"
)

// SrvMountUnit is the systemd unit that makes the data volume visible on
// the VM at /srv.
//
// The unit MUST be named srv.mount: systemd derives a mount unit's name
// from its mount point, and any other name is refused.
//
// source is podman's own mountpoint for the volume, read at setup time
// rather than hardcoded — the path under
// /var/lib/containers/storage/volumes/ is podman's to define.
//
// A bind mount rather than a symlink: /var/lib/containers/storage/volumes
// is 0700 root, so the dev user cannot traverse into it, and loosening
// podman's storage permissions to work around that would be fighting
// podman. Mounting is done once by root; afterwards access checks apply
// to /srv itself, and the volume's files are already owned by the dev
// user's uid because podman is rootful and the container user is created
// with that uid.
//
// ConditionPathIsDirectory keeps a VM whose volume has been removed from
// failing the unit at boot: no source, no mount, no error.
//
// nofail,x-systemd.device-timeout: the source resolves onto a block device
// (podman's volume store), so systemd auto-adds a Requires= on that
// dev-*.device unit. On a VM udev announces the device and it activates; in
// an Apple container there is no udev, so the device unit never appears,
// times out after 90s, and fails the mount job even though the bind mount
// itself succeeded instantly. nofail downgrades that device dependency to a
// non-fatal Wants and the short timeout keeps `enable --now` from blocking;
// on a real VM the device is present immediately, so neither is ever felt.
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

// MountDataVolume installs and activates srv.mount, so /srv on the VM is
// the same tree every container sees at /srv.
//
// Idempotent: an unchanged unit is not rewritten (WriteRootOwnedFile
// short-circuits before sudo), and `enable --now` on an active mount is a
// no-op. A changed unit is re-read and restarted, so a volume that moved
// is followed rather than left pointing at the old path.
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

	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "systemctl", Args: []string{"enable", "--now", "srv.mount"}, Sudo: true,
	}); err != nil || code != 0 {
		return fmt.Errorf("Failed to enable srv.mount (source %s).", source)
	}

	// A changed unit needs the running mount replaced, not just reloaded:
	// `enable --now` leaves an already-active mount alone, so without this
	// a moved source would stay mounted from the old path until reboot.
	if changed {
		if code, err := exec.Run(ctx, exec.Cmd{
			Name: "systemctl", Args: []string{"restart", "srv.mount"}, Sudo: true,
		}); err != nil || code != 0 {
			return fmt.Errorf("Failed to restart srv.mount (source %s).", source)
		}
	}

	ui.OK(out, "/srv mounted from %s.", source)
	return nil
}
