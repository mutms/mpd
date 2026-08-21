package vm

import (
	"strings"
	"testing"
)

// Every one of these directives is load-bearing, and dropping any of them
// fails somewhere far from the config file — so they are asserted here
// rather than discovered on a VM.
func TestDnsmasqConfCarriesTheLoadBearingDirectives(t *testing.T) {
	body := DnsmasqConfBody("10.163.150.1", "mpdbr0")

	for _, tc := range []struct{ directive, why string }{
		{"bind-dynamic",
			"without it dnsmasq fails at boot if it races the bridge"},
		{"interface=mpdbr0",
			"listen-address alone never binds an address that appears later"},
		{"listen-address=10.163.150.1",
			"the gateway is the one address the laptop, the VM and containers all reach"},
		{"local=/test/",
			"a .test name must never be forwarded to a public resolver"},
		{"domain-needed",
			"a bare name must not be forwarded upstream"},
	} {
		if !strings.Contains(body, tc.directive) {
			t.Errorf("missing %q — %s\n%s", tc.directive, tc.why, body)
		}
	}
}

// Records come from /etc/hosts and upstream from /etc/resolv.conf — both
// dnsmasq defaults. Any of these directives would reintroduce a second
// record store or a second resolver in the path.
func TestDnsmasqConfReadsEtcHostsAndResolvConfByDefault(t *testing.T) {
	for _, line := range directives(DnsmasqConfBody("10.163.150.1", "mpdbr0")) {
		for _, forbidden := range []string{"hostsdir", "no-hosts", "addn-hosts", "resolv-file", "server="} {
			if strings.HasPrefix(line, forbidden) {
				t.Errorf("directive %q overrides a default the design relies on", line)
			}
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
	body := DnsmasqConfBody("10.163.222.1", "mpdbr0")
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
	// ReloadDnsmasq depends on `systemctl reload` meaning SIGHUP.
	if !strings.Contains(body, "ExecReload=/bin/kill -HUP") {
		t.Errorf("unit has no SIGHUP reload, so a changed /etc/hosts would never be re-read:\n%s", body)
	}
}
