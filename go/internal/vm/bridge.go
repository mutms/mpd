package vm

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/ui"
)

// The container bridge mpdbr0 is created by systemd-networkd at boot — a static
// bridge — rather than by netavark when the first container attaches. So
// 10.163.<NNN>.1 exists before any container: the resolver binds it at boot,
// caddy binds the gateway without racing, and netavark simply attaches
// container veths to the existing bridge instead of creating and tearing it
// down. That removes the whole "the bridge does not exist until the first
// container attaches" class of fragility.
//
// The name matches NetworkInterface ("mpdbr0") in setup.go, which is what the
// podman network is told to use — so netavark finds this bridge and reuses it.
const (
	BridgeName        = "mpdbr0"
	bridgeNetdevPath  = "/etc/systemd/network/10-mpdbr0.netdev"
	bridgeNetworkPath = "/etc/systemd/network/10-mpdbr0.network"
)

func bridgeNetdev() string {
	return "[NetDev]\nName=" + BridgeName + "\nKind=bridge\n"
}

// bridgeNetwork gives the bridge the VM's gateway address, up at boot with no
// ports attached yet. IPv4 only — IPv6 is disabled VM-wide.
func bridgeNetwork(gatewayCIDR string) string {
	return fmt.Sprintf("[Match]\nName=%s\n\n[Network]\nAddress=%s\nConfigureWithoutCarrier=yes\nLinkLocalAddressing=no\n",
		BridgeName, gatewayCIDR)
}

// EnsureBridge writes the networkd units for the static bridge and applies
// them, so mpdbr0 is up with the gateway address before the podman network and
// dnsmasq are configured.
func EnsureBridge(ctx context.Context, out io.Writer, gatewayCIDR string) error {
	ui.Step(out, "Static container bridge %s (networkd)", BridgeName)

	nd, err := WriteRootOwnedFile(ctx, bridgeNetdevPath, bridgeNetdev())
	if err != nil {
		return err
	}
	nw, err := WriteRootOwnedFile(ctx, bridgeNetworkPath, bridgeNetwork(gatewayCIDR))
	if err != nil {
		return err
	}
	if nd || nw {
		// Reload networkd to create + address the bridge, not a full restart
		// (which could reconfigure the main interface and drop mpd's SSH).
		if code, err := exec.Run(ctx, exec.Cmd{Name: "systemctl", Args: []string{"reload", "systemd-networkd"}, Sudo: true}); err != nil || code != 0 {
			return fmt.Errorf("systemctl reload systemd-networkd failed after writing the %s units", BridgeName)
		}
	}
	// Nudge it up in case the reload lagged, so the podman network and dnsmasq
	// that follow find the bridge present. Harmless if it is already up.
	_, _ = exec.Run(ctx, exec.Cmd{Name: "ip", Args: []string{"link", "set", BridgeName, "up"}, Sudo: true})

	ui.OK(out, "%s up at %s (created at boot, before podman)", BridgeName, gatewayCIDR)
	return nil
}
