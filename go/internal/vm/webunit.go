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
// A USER unit, like the shutdown unit beside it: the server binds
// loopback on a high port and reads only files the dev user already owns,
// so it needs no privileges at all. Linger is enabled by
// InstallShutdownUnit, which is what keeps a user unit running while
// nobody is logged in.
//
// Restart=always because this is a status page: if it dies, the useful
// behaviour is to come back, not to wait for someone to notice.
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

// InstallWebUnit writes, enables and (re)starts the web server unit.
//
// Idempotent, and deliberately a restart rather than a start: `--vm-setup`
// runs after a rebuild, and a server still running the previous binary
// would serve a stale page with no sign of it.
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

// StartUnits brings up the VM-hosted services `--vm-start` is
// responsible for: the status web server and the TLS frontdoor in front
// of it.
//
// Start, not restart: this is the daily path, and a running server should
// keep serving. Failures warn rather than abort — a VM whose projects are
// up but whose status page is down is still a working VM, and saying so
// is more useful than refusing to start anything else.
func StartUnits(ctx context.Context, out io.Writer) error {
	if _, err := exec.Run(ctx, exec.Cmd{
		Name: "systemctl", Args: []string{"--user", "start", WebUnitName},
	}); err != nil {
		ui.Warn(out, "could not start %s: %v", WebUnitName, err)
	}
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "systemctl", Args: []string{"start", CaddyUnit}, Sudo: true,
	}); err != nil || code != 0 {
		ui.Warn(out, "could not start %s — run: mpd --vm-setup", CaddyUnit)
	}
	return nil
}

// UserUnitActive reports whether a user unit is running, for status
// listings of services that systemd owns rather than podman.
func UserUnitActive(ctx context.Context, unit string) bool {
	res, err := exec.Capture(ctx, exec.Cmd{
		Name: "systemctl", Args: []string{"--user", "is-active", "--quiet", unit},
	})
	return err == nil && res.Code == 0
}
