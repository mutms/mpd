package vm

import (
	"context"
	"io"
	"os"
	"path/filepath"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/ui"
)

// WebUnitName is the systemd unit that runs the status web server.
const WebUnitName = "mpd-web.service"

// WebUnitBody renders the user unit for `mpd --web`.
//
// A user unit: the server needs no privileges. Linger, enabled by
// InstallShutdownUnit, keeps it running while nobody is logged in.
func WebUnitBody(binary string) string {
	return `[Unit]
Description=mpd status web server
After=network.target

[Service]
Type=simple
ExecStart=` + binary + ` --web
Restart=always
RestartSec=2

[Install]
WantedBy=default.target`
}

// InstallWebUnit writes, enables and restarts the web server unit.
// Restart, not start: after a rebuild a server on the old binary would
// serve a stale page with no sign of it.
func InstallWebUnit(ctx context.Context) error {
	unitDir := filepath.Join(Home(), ".config", "systemd", "user")
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(unitDir, WebUnitName),
		[]byte(WebUnitBody(BinaryPath)), 0o644); err != nil {
		return err
	}
	for _, args := range [][]string{
		{"--user", "daemon-reload"},
		{"--user", "enable", WebUnitName},
		{"--user", "restart", WebUnitName},
	} {
		if code, err := exec.Run(ctx, exec.Cmd{Name: "systemctl", Args: args}); err != nil || code != 0 {
			return err
		}
	}
	return nil
}

// StartUnits brings up the resolver, the status web server and its TLS
// frontdoor for `--vm-start`. The resolver goes first: the other two
// serve names it publishes. Start, not restart, on the daily path;
// failures warn rather than abort.
func StartUnits(ctx context.Context, out io.Writer) error {
	for _, unit := range []string{DnsmasqUnit, CaddyUnit} {
		if code, err := exec.Run(ctx, exec.Cmd{
			Name: "systemctl", Args: []string{"start", unit}, Sudo: true,
		}); err != nil || code != 0 {
			ui.Warn(out, "could not start %s — run: mpd --vm-setup", unit)
		}
	}
	if _, err := exec.Run(ctx, exec.Cmd{
		Name: "systemctl", Args: []string{"--user", "start", WebUnitName},
	}); err != nil {
		ui.Warn(out, "could not start %s: %v", WebUnitName, err)
	}
	return nil
}

// UnitActive reports whether a systemd unit is running. user selects the
// scope: a system unit and a user unit of the same name are different
// units.
func UnitActive(ctx context.Context, unit string, user bool) bool {
	args := []string{"is-active", "--quiet", unit}
	if user {
		args = append([]string{"--user"}, args...)
	}
	res, err := exec.Capture(ctx, exec.Cmd{Name: "systemctl", Args: args})
	return err == nil && res.Code == 0
}
