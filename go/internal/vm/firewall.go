package vm

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/ui"
)

// The container subnet 10.163.<NNN>.0/24 must never be reachable from outside
// the VM. Everything the Mac (and anything on the LAN) legitimately needs is
// served by the VM itself on the gateway .1 — caddy (the TLS frontdoor that
// reverse-proxies to the containers) and dnsmasq — plus SSH ProxyJump through
// the box for shells into runtime containers. In every case the container hop
// is made *inside* the VM, so no external party ever needs a route to a
// container IP.
//
// This installs an independent nftables table that drops NEW forwarded
// connections into the subnet from any interface but the bridge itself, while
// leaving the container→internet masquerade (netavark's rules, a separate
// table) and all established/return traffic untouched. An nft `drop` verdict is
// terminal across base chains at the same hook, so this wins regardless of
// netavark's accepts, and living in its own table means netavark never flushes
// it.
//
// mpd-virt independently narrows the WireGuard AllowedIPs to just the gateway
// .1/32, so the Mac cannot even put a container-subnet packet onto the tunnel —
// this box-side drop is the belt to that braces.
const (
	firewallTable    = "mpd_firewall"
	firewallUnit     = "mpd-firewall.service"
	firewallUnitPath = "/etc/systemd/system/" + firewallUnit
	firewallRulePath = "/etc/mpd/mpd-firewall.nft"
	nftBin           = "/usr/sbin/nft"
)

// firewallRuleBody renders the idempotent nft program. The add/delete/add
// preamble gives our table a clean slate on every apply without touching any
// other table (netavark's included).
func firewallRuleBody(subnet string) string {
	return fmt.Sprintf(`#!%[4]s -f
# Managed by mpd vm-setup. Seals the container subnet %[2]s from outside the VM;
# container outbound (masquerade) and all return traffic are left untouched.
add table inet %[1]s
delete table inet %[1]s
table inet %[1]s {
	chain forward {
		type filter hook forward priority -10; policy accept;
		# Return traffic for container-initiated flows always passes.
		ct state established,related accept
		# Drop NEW connections into the container subnet arriving on anything
		# but the bridge itself (wg0 from the Mac, eth0 from the LAN, …).
		# Container outbound (iif %[3]s) and VM-local traffic are unaffected.
		ip daddr %[2]s iifname != "%[3]s" ct state new drop
	}
}
`, firewallTable, subnet, BridgeName, nftBin)
}

// firewallUnitBody renders the oneshot that (re)applies the ruleset at boot, so
// the block survives reboots independently of when netavark builds its rules.
func firewallUnitBody() string {
	return fmt.Sprintf(`[Unit]
Description=mpd container-subnet firewall
Documentation=file:///opt/mpd/docs/NETWORKING.md
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

// EnsureFirewall installs the container-subnet firewall: it writes the nft
// ruleset and a boot-time oneshot that applies it, then applies it now.
// Idempotent — the ruleset self-replaces and the unit is reloaded only when it
// changes.
func EnsureFirewall(ctx context.Context, out io.Writer, subnet string) error {
	ui.Step(out, "Container-subnet firewall (nftables — seal %s from outside)", subnet)

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
	// restart, not start: re-applies the (idempotent) ruleset on a re-run and
	// starts it when stopped.
	if code, err := exec.Run(ctx, exec.Cmd{Name: "systemctl", Args: []string{"restart", firewallUnit}, Sudo: true}); err != nil || code != 0 {
		return fmt.Errorf("systemctl restart %s failed — check `journalctl -u %s`", firewallUnit, firewallUnit)
	}

	ui.OK(out, "container subnet %s sealed from outside; outbound NAT kept (nft table %s)", subnet, firewallTable)
	return nil
}
