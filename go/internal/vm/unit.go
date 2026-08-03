package vm

import (
	"context"
	"os"
	"path/filepath"

	"github.com/mutms/mpd/go/internal/exec"
)

// UnitBody renders the systemd user unit that brackets the VM lifecycle:
// `mpd --vm-start` at boot, `mpd --vm-stop` on shutdown, reboot and suspend.
//
// The shutdown half is the point. Without it podman SIGTERMs the
// database containers mid-flight during teardown, and the next boot
// finds postgres doing crash recovery; with it, the mpd-pre-stop hooks
// get to shut each engine down cleanly.
//
// `ExecStart=-` (the leading dash) makes a failed boot-time start
// non-fatal, so the unit still reaches active and ExecStop still fires
// on shutdown. Worst case the developer runs `mpd --vm-start` by hand —
// what must never be lost is the graceful-stop path.
//
// A USER unit, not a system one: the privilege rule forbids identity
// switching, and mpd runs as the dev user. That is also why linger has
// to be enabled — see InstallShutdownUnit.
func UnitBody(binary string) string {
	return `[Unit]
Description=mpd lifecycle (start on boot, graceful stop on shutdown)
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target suspend.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-` + binary + ` --vm-start
ExecStop=` + binary + ` --vm-stop
TimeoutStartSec=300
TimeoutStopSec=180

[Install]
WantedBy=default.target`
}

// InstallShutdownUnit writes, enables and starts the unit. Idempotent:
// it rewrites and re-enables on every call.
//
// The start is `--no-block`, and that is load-bearing. This runs inside
// `mpd --vm-setup`, which holds mpd's command flock; the unit's
// ExecStart (`mpd --vm-start`) takes that same lock. A blocking start
// would deadlock — vm-setup waits for `systemctl start` to return,
// `start` waits for --vm-start, --vm-start waits for the lock vm-setup
// holds — breaking only at TimeoutStartSec (the unit lands `failed` after
// a 5-minute hang). `--no-block` enqueues the job and returns, so
// vm-setup finishes and releases the lock, then --vm-start proceeds and
// the unit reaches active.
func InstallShutdownUnit(ctx context.Context, user string) error {
	unitDir := filepath.Join(Home(), ".config", "systemd", "user")
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(unitDir, "mpd.service"),
		[]byte(UnitBody(BinaryPath)), 0o644); err != nil {
		return err
	}

	for _, args := range [][]string{
		{"--user", "daemon-reload"},
		{"--user", "enable", "mpd.service"},
		{"--user", "start", "--no-block", "mpd.service"},
	} {
		_, _ = exec.Run(ctx, exec.Cmd{Name: "systemctl", Args: args})
	}

	// Linger keeps the user's systemd manager alive across logout —
	// without it the unit cannot fire on an unattended shutdown, which
	// is exactly the case it exists for.
	_, _ = exec.Run(ctx, exec.Cmd{
		Name: "loginctl", Args: []string{"enable-linger", user}, Sudo: true,
	})
	return nil
}
