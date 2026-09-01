package vm

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/ui"
)

// The firewall seals the container subnet from the LAN while the bridge
// and wg0 may route in; see docs/networking.md ("The container-subnet
// firewall"). It lives in its own table so netavark never flushes it,
// and an nft drop verdict wins across base chains at the same hook.
const (
	firewallTable    = "mpd_firewall"
	firewallUnit     = "mpd-firewall.service"
	firewallUnitPath = "/etc/systemd/system/" + firewallUnit
	firewallRulePath = "/etc/mpd/mpd-firewall.nft"
	nftBin           = "/usr/sbin/nft"
)

// FirewallLoaded reports whether the firewall table is in the running
// ruleset. It lives here so the table name stays private.
func FirewallLoaded(ctx context.Context) bool {
	// "nft", not nftBin: exec resolves allow-listed bare names itself. A
	// path would miss the allow-list and always report "not loaded".
	res, err := exec.Capture(ctx, exec.Cmd{
		Name: "nft",
		Args: []string{"list", "table", "inet", firewallTable},
		Sudo: true,
	})
	return err == nil && !res.Failed()
}

// firewallRuleBody renders the nft program. The add/delete/add preamble
// resets only this table, never netavark's.
func firewallRuleBody(subnet string) string {
	return fmt.Sprintf(`#!%[4]s -f
# Managed by mpd vm-setup. Seals the container subnet %[2]s from the LAN/public
# side of the VM; the WireGuard overlay (wg0) legitimately carries the whole
# subnet to the developer's Mac. Container outbound (masquerade) and all return
# traffic are left untouched.
add table inet %[1]s
delete table inet %[1]s
table inet %[1]s {
	chain prerouting {
		# Must run before netavark's DNAT (priority -100): a port published
		# on a subnet address is still addressed to the subnet here, and a
		# packet dropped here reaches neither the forward nor the input hook.
		type filter hook prerouting priority -150; policy accept;
		ct state established,related accept
		ip daddr %[2]s iifname != { "%[3]s", "wg0", "lo" } ct state new drop
	}
	chain forward {
		# The VM forwards nothing that arrives from the LAN, whatever podman
		# network or published port it is aimed at. Container outbound
		# arrives on a bridge; wg0 carries the laptop.
		type filter hook forward priority -10; policy accept;
		ct state established,related accept
		iifname != { "%[3]s", "wg0", "podman*" } ct state new drop
	}
}
`, firewallTable, subnet, BridgeName, nftBin)
}

func firewallUnitBody() string {
	return fmt.Sprintf(`[Unit]
Description=mpd container-subnet firewall
Documentation=file:///opt/mpd/docs/networking.md
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=%[1]s -f %[2]s

[Install]
WantedBy=multi-user.target
`, nftBin, firewallRulePath)
}

// EnsureFirewall writes the nft ruleset and a boot-time oneshot that
// applies it, then applies it now. Idempotent.
func EnsureFirewall(ctx context.Context, out io.Writer, subnet string) error {
	ui.Step(out, "Container-subnet firewall (nftables — seal %s from the LAN; wg0 allowed)", subnet)

	if _, err := WriteRootOwnedFile(ctx, firewallRulePath, firewallRuleBody(subnet)); err != nil {
		return err
	}
	changed, err := WriteRootOwnedFile(ctx, firewallUnitPath, firewallUnitBody())
	if err != nil {
		return err
	}
	if changed {
		if code, err := exec.Run(ctx, exec.Cmd{Name: "systemctl", Args: []string{"daemon-reload"}, Sudo: true}); err != nil || code != 0 {
			return fmt.Errorf("systemctl daemon-reload failed after writing %s", firewallUnitPath)
		}
	}
	if code, err := exec.Run(ctx, exec.Cmd{Name: "systemctl", Args: []string{"enable", firewallUnit}, Sudo: true}); err != nil || code != 0 {
		return fmt.Errorf("systemctl enable %s failed", firewallUnit)
	}
	// restart, not start: re-applies the ruleset on a re-run and starts it
	// when stopped.
	if code, err := exec.Run(ctx, exec.Cmd{Name: "systemctl", Args: []string{"restart", firewallUnit}, Sudo: true}); err != nil || code != 0 {
		return fmt.Errorf("systemctl restart %s failed — check `journalctl -u %s`", firewallUnit, firewallUnit)
	}

	ui.OK(out, "container subnet %s sealed from the LAN; wg0 carries it, outbound NAT kept (nft table %s)", subnet, firewallTable)
	return nil
}
