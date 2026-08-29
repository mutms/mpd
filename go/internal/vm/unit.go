package vm

import (
	"context"
	"os"
	"path/filepath"

	"github.com/mutms/mpd/go/internal/exec"
)

// UnitBody renders the user unit that runs `mpd --vm-start` at boot and
// `mpd --vm-stop` on shutdown.
//
// The shutdown half is the point: without it podman SIGTERMs database
// containers mid-flight and the next boot finds crash recovery.
// `ExecStart=-` keeps a failed start non-fatal so ExecStop still fires.
// A user unit because mpd runs as the dev user; hence linger, see
// InstallShutdownUnit.
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

// InstallShutdownUnit writes, enables and starts the unit. Idempotent.
//
// The start MUST be `--no-block`: this runs under mpd's command flock,
// and the unit's ExecStart takes the same lock, so a blocking start
// deadlocks until TimeoutStartSec.
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

	// Linger keeps the user manager alive across logout; without it the
	// unit cannot fire on an unattended shutdown.
	_, _ = exec.Run(ctx, exec.Cmd{
		Name: "loginctl", Args: []string{"enable-linger", user}, Sudo: true,
	})
	return nil
}
