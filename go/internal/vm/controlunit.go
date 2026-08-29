package vm

import (
	"context"
	"os"
	"path/filepath"

	"github.com/mutms/mpd/go/internal/exec"
)

// ControlUnitName is the systemd unit that serves project commands sent
// from inside runtime containers.
const ControlUnitName = "mpd-control.service"

// ControlUnitBody renders the user unit for `mpd --control`.
//
// A user unit: the daemon needs no privileges, and a dev-user-owned
// socket is what lets the runtime connect as the UID-matched user.
// Restart=always: a developer inside a runtime cannot start it.
func ControlUnitBody(binary string) string {
	return `[Unit]
Description=mpd control socket for runtime containers
After=network.target

[Service]
Type=simple
ExecStart=` + binary + ` --control
Restart=always
RestartSec=2

[Install]
WantedBy=default.target`
}

// InstallControlUnit writes, enables and restarts the control daemon.
//
// Restart, not start: after a rebuild a daemon on the old binary would
// keep serving the old guard.
func InstallControlUnit(ctx context.Context) error {
	unitDir := filepath.Join(Home(), ".config", "systemd", "user")
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(unitDir, ControlUnitName),
		[]byte(ControlUnitBody(BinaryPath)), 0o644); err != nil {
		return err
	}
	for _, args := range [][]string{
		{"--user", "daemon-reload"},
		{"--user", "enable", ControlUnitName},
		{"--user", "restart", ControlUnitName},
	} {
		if code, err := exec.Run(ctx, exec.Cmd{Name: "systemctl", Args: args}); err != nil || code != 0 {
			return err
		}
	}
	return nil
}
