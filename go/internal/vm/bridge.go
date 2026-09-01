package vm

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/ui"
)

// The bridge is a static systemd oneshot, not netavark-created, so the
// gateway address exists at boot before the resolver and caddy bind it.
// Plain `ip` commands, not systemd-networkd: networkd cannot manage links
// inside an Apple container's sandbox. The name must match
// NetworkInterface in setup.go so netavark reuses the bridge.
// See docs/networking.md.
const (
	BridgeName     = "mpdbr0"
	bridgeUnit     = "mpd-bridge.service"
	bridgeUnitPath = "/etc/systemd/system/" + bridgeUnit

	// Legacy systemd-networkd units. Removed on sight: left in place,
	// networkd would fight the oneshot over the bridge address.
	legacyNetdevPath  = "/etc/systemd/network/10-mpdbr0.netdev"
	legacyNetworkPath = "/etc/systemd/network/10-mpdbr0.network"
)

// bridgeUnitBody renders the oneshot unit. It is ordered before the
// resolver, and every step is idempotent, so re-runs are harmless.
//
// The bridge carries two VM addresses: the gateway, where the resolver
// and the apex caddy bind, and the project address, where the project
// caddy binds. Both are VM-local; nothing on the bridge routes to them.
func bridgeUnitBody(gatewayCIDR, projectsCIDR string) string {
	return fmt.Sprintf(`[Unit]
Description=mpd static container bridge (%[1]s)
Documentation=file:///opt/mpd/docs/networking.md
After=network-pre.target
Before=network.target %[2]s

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'ip link show %[1]s >/dev/null 2>&1 || ip link add %[1]s type bridge; ip addr replace %[3]s dev %[1]s; ip addr replace %[4]s dev %[1]s; ip link set %[1]s up'

[Install]
WantedBy=multi-user.target
`, BridgeName, DnsmasqUnit, gatewayCIDR, projectsCIDR)
}

// EnsureBridge installs and starts the bridge oneshot so mpdbr0 is up
// before the podman network and dnsmasq are configured.
func EnsureBridge(ctx context.Context, out io.Writer, gatewayCIDR, projectsCIDR string) error {
	ui.Step(out, "Static container bridge %s (systemd oneshot)", BridgeName)

	_, _ = exec.Run(ctx, exec.Cmd{Name: "rm", Args: []string{"-f", legacyNetdevPath, legacyNetworkPath}, Sudo: true})

	changed, err := WriteRootOwnedFile(ctx, bridgeUnitPath, bridgeUnitBody(gatewayCIDR, projectsCIDR))
	if err != nil {
		return err
	}
	if changed {
		if code, err := exec.Run(ctx, exec.Cmd{Name: "systemctl", Args: []string{"daemon-reload"}, Sudo: true}); err != nil || code != 0 {
			return fmt.Errorf("systemctl daemon-reload failed after writing %s", bridgeUnitPath)
		}
	}
	if code, err := exec.Run(ctx, exec.Cmd{Name: "systemctl", Args: []string{"enable", bridgeUnit}, Sudo: true}); err != nil || code != 0 {
		return fmt.Errorf("systemctl enable %s failed", bridgeUnit)
	}
	// restart, not start: re-applies the unit on a re-run and starts it
	// when stopped.
	if code, err := exec.Run(ctx, exec.Cmd{Name: "systemctl", Args: []string{"restart", bridgeUnit}, Sudo: true}); err != nil || code != 0 {
		return fmt.Errorf("systemctl restart %s failed — check `journalctl -u %s`", bridgeUnit, bridgeUnit)
	}

	ui.OK(out, "%s up at %s and %s (systemd oneshot, at boot before podman)", BridgeName, gatewayCIDR, projectsCIDR)
	return nil
}
