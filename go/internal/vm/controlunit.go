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
// A USER unit, for the same reason as the web server beside it: the daemon
// binds Unix sockets under /var/lib/mpd/run and spawns mpd as the dev user,
// so it needs no privileges of its own. Whatever privilege a forwarded verb
// requires it acquires the same way a VM terminal does — per-operation
// sudo, inside the child.
//
// This is also what keeps the socket's permissions meaningful: the socket
// is owned by the dev user, and the runtime connects as the same UID-matched
// user. A root-owned daemon would have to widen that.
//
// Restart=always: a developer inside a runtime has no way to start it, and
// the failure mode of a dead daemon is that mpd simply stops working there.
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

// InstallControlUnit writes, enables and (re)starts the control daemon.
//
// Restart rather than start, like InstallWebUnit: `--vm-setup` runs after a
// rebuild, and a daemon still running the previous binary would keep
// serving the previous guard — the one place where a stale binary is a
// security question rather than a cosmetic one.
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
