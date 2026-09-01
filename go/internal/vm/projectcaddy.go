package vm

import (
	"context"
	"fmt"

	"github.com/mutms/mpd/go/internal/exec"
)

// ProjectCaddyUnitName is the systemd unit serving every project vhost.
// Distinct from CaddyUnit, which serves only the zone apex; see
// docs/networking.md.
const ProjectCaddyUnitName = "mpd-caddy.service"

const projectCaddyUnitPath = "/etc/systemd/system/" + ProjectCaddyUnitName

// ProjectCaddyUnitBody renders the unit.
//
// Runs as the dev user: the project keys under /srv/meta are 0600 and
// dev-owned, so the process moves rather than the key.
// AmbientCapabilities keeps :443 bindable without root.
func ProjectCaddyUnitBody(user, bindIP string) string {
	return fmt.Sprintf(`[Unit]
Description=mpd project TLS frontdoor (caddy)
Documentation=file:///opt/mpd/docs/architecture.md
After=network.target mpd-bridge.service
Wants=mpd-bridge.service

[Service]
User=%s
Group=%s
RuntimeDirectory=mpd-caddy
Environment=CADDYFILE=/run/mpd-caddy/Caddyfile
Environment=MPD_CADDY_BIND=%s
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=/bin/bash /opt/mpd/assets/vm/caddy/mpd-caddy.sh
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
`, user, user, bindIP)
}

// InstallProjectCaddyUnit writes, enables and starts the project
// frontdoor. Idempotent: an unchanged unit is not restarted, so
// `--vm-setup` does not drop live connections.
func InstallProjectCaddyUnit(ctx context.Context, user, bindIP string) error {
	changed, err := WriteRootOwnedFile(ctx, projectCaddyUnitPath,
		ProjectCaddyUnitBody(user, bindIP))
	if err != nil {
		return err
	}
	if changed {
		if code, err := exec.Run(ctx, exec.Cmd{
			Name: "systemctl", Args: []string{"daemon-reload"}, Sudo: true,
		}); err != nil || code != 0 {
			return fmt.Errorf("systemctl daemon-reload failed after writing %s.", projectCaddyUnitPath)
		}
	}
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "systemctl", Args: []string{"enable", ProjectCaddyUnitName}, Sudo: true,
	}); err != nil || code != 0 {
		return fmt.Errorf("systemctl enable %s failed.", ProjectCaddyUnitName)
	}
	action := "start"
	if changed {
		action = "restart"
	}
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "systemctl", Args: []string{action, ProjectCaddyUnitName}, Sudo: true,
	}); err != nil || code != 0 {
		return fmt.Errorf("systemctl %s %s failed — check `journalctl -u %s`.",
			action, ProjectCaddyUnitName, ProjectCaddyUnitName)
	}
	return nil
}
