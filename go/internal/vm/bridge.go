package vm

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/ui"
)

// The container bridge mpdbr0 is created at boot by a small systemd oneshot —
// a static bridge — rather than by netavark when the first container attaches.
// So 10.163.<NNN>.1 exists before any container: the resolver binds it at
// boot, caddy binds the gateway without racing, and netavark simply attaches
// container veths to the existing bridge instead of creating and tearing it
// down. That removes the whole "the bridge does not exist until the first
// container attaches" class of fragility.
//
// The bridge is made with plain `ip` commands, not systemd-networkd. networkd
// cannot manage links inside an Apple container's restricted sandbox (no BPF,
// links stay pending), so a declarative .netdev/.network is never applied
// there — it produced a bridge with no address. `ip link add` works the same
// on a Parallels VM and an Apple container, and netavark does not care how the
// bridge was made, only that a bridge named mpdbr0 with the gateway address
// exists to attach veths to.
//
// The name matches NetworkInterface ("mpdbr0") in setup.go, which is what the
// podman network is told to use — so netavark finds this bridge and reuses it.
const (
	BridgeName     = "mpdbr0"
	bridgeUnit     = "mpd-bridge.service"
	bridgeUnitPath = "/etc/systemd/system/" + bridgeUnit

	// Legacy systemd-networkd units from the previous static-bridge approach.
	// Removed on sight: left in place, networkd (on the VMs where it runs)
	// would try to manage mpdbr0 too and fight the oneshot over the address.
	legacyNetdevPath  = "/etc/systemd/network/10-mpdbr0.netdev"
	legacyNetworkPath = "/etc/systemd/network/10-mpdbr0.network"
)

// bridgeUnitBody renders the oneshot unit. Ordered before the resolver — and so
// before caddy and any container attach — and enabled at boot, it creates the
// bridge, gives it the gateway address, and brings it up. Every step is
// idempotent, so a re-run or a re-applied unit is harmless: the bridge is only
// added when absent, and `addr replace` overwrites rather than duplicates.
func bridgeUnitBody(gatewayCIDR string) string {
	return fmt.Sprintf(`[Unit]
Description=mpd static container bridge (%[1]s)
Documentation=file:///opt/mpd/docs/NETWORKING.md
After=network-pre.target
Before=network.target %[2]s

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'ip link show %[1]s >/dev/null 2>&1 || ip link add %[1]s type bridge; ip addr replace %[3]s dev %[1]s; ip link set %[1]s up'

[Install]
WantedBy=multi-user.target
`, BridgeName, DnsmasqUnit, gatewayCIDR)
}

// EnsureBridge installs and starts the bridge oneshot, so mpdbr0 is up with the
// gateway address before the podman network and dnsmasq are configured, and is
// recreated on every boot before anything binds or attaches.
func EnsureBridge(ctx context.Context, out io.Writer, gatewayCIDR string) error {
	ui.Step(out, "Static container bridge %s (systemd oneshot)", BridgeName)

	// Drop the previous networkd units if present, so networkd does not also
	// try to own mpdbr0 on VMs where it runs.
	_, _ = exec.Run(ctx, exec.Cmd{Name: "rm", Args: []string{"-f", legacyNetdevPath, legacyNetworkPath}, Sudo: true})

	changed, err := WriteRootOwnedFile(ctx, bridgeUnitPath, bridgeUnitBody(gatewayCIDR))
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
	// restart, not start: re-applies the (idempotent) unit on a re-run and
	// starts it when stopped. This is what actually creates + addresses the
	// bridge now, before the podman network and dnsmasq that follow.
	if code, err := exec.Run(ctx, exec.Cmd{Name: "systemctl", Args: []string{"restart", bridgeUnit}, Sudo: true}); err != nil || code != 0 {
		return fmt.Errorf("systemctl restart %s failed — check `journalctl -u %s`", bridgeUnit, bridgeUnit)
	}

	ui.OK(out, "%s up at %s (systemd oneshot, at boot before podman)", BridgeName, gatewayCIDR)
	return nil
}
