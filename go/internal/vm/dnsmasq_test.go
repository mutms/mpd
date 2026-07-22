package vm

import (
	"strings"
	"testing"
)

// Every one of these directives is load-bearing, and dropping any of them
// fails somewhere far from the config file — so they are asserted here
// rather than discovered on a VM.
func TestDnsmasqConfCarriesTheLoadBearingDirectives(t *testing.T) {
	body := DnsmasqConfBody("10.163.150.1", "mpdbr0", "/var/lib/mpd/state/dns")

	for _, tc := range []struct{ directive, why string }{
		{"bind-dynamic",
			"without it dnsmasq fails at boot, before podman has created the bridge"},
		{"interface=mpdbr0",
			"listen-address alone never binds an address that appears later"},
		{"listen-address=10.163.150.1",
			"the gateway is the one address the laptop, the VM and containers all reach"},
		{"local=/test/",
			"a .test name must never be forwarded to a public resolver"},
		{"hostsdir=/var/lib/mpd/state/dns",
			"records are picked up from here without a restart"},
		{"no-hosts",
			"the VM's own /etc/hosts is not part of the zone"},
		{"resolv-file=/run/systemd/resolve/resolv.conf",
			"upstream must follow the host's links, and must not be the resolved stub"},
	} {
		if !strings.Contains(body, tc.directive) {
			t.Errorf("missing %q — %s\n%s", tc.directive, tc.why, body)
		}
	}
}

// Forwarding to 127.0.0.53 would loop: systemd-resolved routes ~mpd.test
// straight back here, so a query for a name this resolver cannot answer
// would bounce between the two.
func TestDnsmasqDoesNotForwardToTheResolvedStub(t *testing.T) {
	for _, line := range directives(DnsmasqConfBody("10.163.150.1", "mpdbr0", "/var/lib/mpd/state/dns")) {
		if strings.Contains(line, "127.0.0.53") {
			t.Errorf("directive forwards to the systemd-resolved stub: %q", line)
		}
	}
}

// directives drops comments and blanks, leaving what dnsmasq acts on. The
// comments explain the reasoning and name the addresses being argued
// against, so a whole-body match would read them as configuration.
func directives(body string) []string {
	var out []string
	for _, raw := range strings.Split(body, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		out = append(out, line)
	}
	return out
}

// The listen address is the only thing that varies per VM, and getting it
// wrong makes the resolver answer for a subnet it is not on.
func TestDnsmasqConfListensOnTheGivenAddressOnly(t *testing.T) {
	body := DnsmasqConfBody("10.163.222.1", "mpdbr0", "/var/lib/mpd/state/dns")
	if !strings.Contains(body, "listen-address=10.163.222.1") {
		t.Errorf("wrong listen address:\n%s", body)
	}
	for _, line := range directives(body) {
		if strings.Contains(line, "10.163.") && !strings.Contains(line, "10.163.222.1") {
			t.Errorf("another VM's address leaked into a directive: %q", line)
		}
	}
}

// The unit must name mpd's own config file. Left to the default, dnsmasq
// reads /etc/dnsmasq.conf — the sysadmin's file, which mpd does not own
// and must not depend on.
func TestDnsmasqUnitNamesMpdsConfigFile(t *testing.T) {
	body := DnsmasqUnitBody(DnsmasqConfPath)
	if !strings.Contains(body, "--conf-file="+DnsmasqConfPath) {
		t.Errorf("unit does not pin the config file:\n%s", body)
	}
	// Type=simple with a backgrounding daemon leaves systemd tracking a
	// process that has already exited.
	if !strings.Contains(body, "--keep-in-foreground") {
		t.Errorf("unit lets dnsmasq daemonise under Type=simple:\n%s", body)
	}
}
