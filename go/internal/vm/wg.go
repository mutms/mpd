package vm

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/ui"
)

// wg0 is the VM's WireGuard endpoint; see docs/networking.md. vm-setup
// provisions the VM's half; the peer is added by mpd-virt and persisted
// with `wg-quick save`.
const (
	wgInterface = "wg0"
	wgListen    = 51820
	wgKeyPath   = "/etc/wireguard/mpd.key"
	wgConfPath  = "/etc/wireguard/wg0.conf"
	fwdSysctl   = "/etc/sysctl.d/99-mpd-forwarding.conf"
)

const fwdSysctlBody = `net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.default.forwarding = 0
`

// EnsureWireGuard guarantees ip_forward, generates the key if absent,
// writes the wg0 [Interface] only when missing — so the host-added peer
// is never clobbered on a re-run — and enables wg0 at boot.
func EnsureWireGuard(ctx context.Context, out io.Writer, octet int) error {
	ui.Step(out, "WireGuard endpoint (%s)", wgInterface)

	// Packets arriving on wg0 for 10.163.<NNN>.x must be forwarded to the
	// bridge. IPv6 forwarding stays off: the firewall seals IPv4 subnets
	// only, and no container network has IPv6.
	if _, err := WriteRootOwnedFile(ctx, fwdSysctl, fwdSysctlBody); err != nil {
		return err
	}

	unit := "wg-quick@" + wgInterface
	script := fmt.Sprintf(`set -e
sudo sysctl -w net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=0 net.ipv6.conf.default.forwarding=0 >/dev/null
sudo install -d -m 700 /etc/wireguard
# /etc/wireguard is root-only, so a plain test -f always says "missing".
sudo test -f %[1]s || { umask 077; wg genkey | sudo tee %[1]s >/dev/null && sudo chmod 600 %[1]s; }
if ! sudo test -f %[2]s; then
  printf '[Interface]\nAddress = 10.163.0.%[3]d/32\nListenPort = %[4]d\nPrivateKey = %%s\n' "$(sudo cat %[1]s)" | sudo tee %[2]s >/dev/null
  sudo chmod 600 %[2]s
  sudo systemctl restart %[5]s
fi
sudo systemctl enable %[5]s >/dev/null 2>&1 || true
sudo systemctl start %[5]s
`, wgKeyPath, wgConfPath, octet, wgListen, unit)
	if code, err := exec.Run(ctx, exec.Cmd{Name: "bash", Args: []string{"-c", script}}); err != nil || code != 0 {
		return fmt.Errorf("bringing up %s failed", wgInterface)
	}

	ui.OK(out, "%s up (Address 10.163.0.%d/32, listen :%d, ip_forward on) — peer added by mpd-virt", wgInterface, octet, wgListen)
	return nil
}
