package net

import (
	"os"
	"path/filepath"
	"testing"
)

func mustNew(t *testing.T, octet int) Net {
	t.Helper()
	n, err := New(octet)
	if err != nil {
		t.Fatalf("New(%d) failed: %v", octet, err)
	}
	return n
}

func TestAddressing(t *testing.T) {
	tests := []struct {
		octet   int
		zone    string
		subnet  string
		gateway string
	}{
		{100, "100.mpd.test", "10.163.100.0/24", "10.163.100.1"},
		{150, "150.mpd.test", "10.163.150.0/24", "10.163.150.1"},
		{222, "222.mpd.test", "10.163.222.0/24", "10.163.222.1"},
	}
	for _, tc := range tests {
		n := mustNew(t, tc.octet)
		if got := n.Zone(); got != tc.zone {
			t.Errorf("VM %d Zone() = %q, want %q", tc.octet, got, tc.zone)
		}
		if got := n.Subnet(); got != tc.subnet {
			t.Errorf("VM %d Subnet() = %q, want %q", tc.octet, got, tc.subnet)
		}
		if got := n.Gateway(); got != tc.gateway {
			t.Errorf("VM %d Gateway() = %q, want %q", tc.octet, got, tc.gateway)
		}
	}
}

func TestVMIDIsThreeDigit(t *testing.T) {
	for octet, want := range map[int]string{100: "100", 137: "137", 254: "254"} {
		if got := mustNew(t, octet).VMID(); got != want {
			t.Errorf("New(%d).VMID() = %q, want %q", octet, got, want)
		}
	}
}

func TestNewRejectsOutOfRange(t *testing.T) {
	for _, octet := range []int{-1, 0, 1, 99, 255, 256, 999} {
		if _, err := New(octet); err == nil {
			t.Errorf("New(%d) = nil error, want rejection", octet)
		}
	}
}

func TestNaming(t *testing.T) {
	n := mustNew(t, 150)
	tests := map[string]string{
		n.Host("moodle45"):   "moodle45.150.mpd.test",
		n.Service("adminer"): "adminer.svc.150.mpd.test",
		n.RuntimeFQDN():      "runtime.150.mpd.test",
		n.DB("pg17"):         "pg17.db.150.mpd.test",
		n.VMServiceRecord():  "vm.150.mpd.test",
		// Not in the zone: an ssh alias, not a DNS name.
		n.RuntimeAlias(): "mpd-150-runtime",
	}
	for got, want := range tests {
		if got != want {
			t.Errorf("got %q, want %q", got, want)
		}
	}
}

// The bare root domain must not be in any zone: with two VMs up it
// could only mean one of them.
func TestIsInZone(t *testing.T) {
	n := mustNew(t, 150)
	in := []string{
		"150.mpd.test",
		"moodle45.150.mpd.test",
		"behat.moodle45.150.mpd.test",
		"runtime.150.mpd.test",
	}
	for _, name := range in {
		if !n.IsInZone(name) {
			t.Errorf("IsInZone(%q) = false, want true", name)
		}
	}
	out := []string{
		"mpd.test",              // bare apex — deliberately not ours
		"moodle45.mpd.test",     // pre-per-VM-zone name
		"moodle45.180.mpd.test", // another VM's zone
		"180.mpd.test",
		"example.com",
		"",
		// Suffix matching must respect the dot boundary.
		"evil150.mpd.test",
	}
	for _, name := range out {
		if n.IsInZone(name) {
			t.Errorf("IsInZone(%q) = true, want false", name)
		}
	}
}

func TestHostOctet(t *testing.T) {
	n := mustNew(t, 150)
	if host, ok := n.HostOctet("10.163.150.100"); !ok || host != 100 {
		t.Errorf("HostOctet(own subnet) = (%d, %v), want (100, true)", host, ok)
	}
	// An address in another VM's /24 must not consume a slot here.
	if _, ok := n.HostOctet("10.163.180.100"); ok {
		t.Error("HostOctet(other VM's subnet) = ok, want not ok")
	}
	for _, addr := range []string{"10.1.1.1", "10.163.150", "", "10.163.150.x", "not an ip"} {
		if _, ok := n.HostOctet(addr); ok {
			t.Errorf("HostOctet(%q) = ok, want not ok", addr)
		}
	}
	if !n.Contains("10.163.150.4") {
		t.Error("Contains(own portal IP) = false, want true")
	}
}

func TestVMIDFromHostname(t *testing.T) {
	cases := map[string]string{
		"mpd-150":          "150",
		"mpd-224":          "224",
		"mpd-136.mpd.test": "136", // FQDN form: only the short name counts
		"  mpd-137\n":      "137", // whitespace trimmed
		"debian":           "",    // not an mpd host
		"":                 "",
	}
	for in, want := range cases {
		if got := VMIDFromHostname(in); got != want {
			t.Errorf("VMIDFromHostname(%q) = %q, want %q", in, got, want)
		}
	}
}

// setHostname points Current() at a fixture hostname file.
func setHostname(t *testing.T, body string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "hostname")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("writing fixture: %v", err)
	}
	t.Setenv("MPD_HOSTNAME_FILE", path)
}

func TestCurrent(t *testing.T) {
	setHostname(t, "mpd-150\n")
	n, err := Current()
	if err != nil {
		t.Fatalf("Current() failed: %v", err)
	}
	if n.Zone() != "150.mpd.test" {
		t.Errorf("Zone() = %q, want %q", n.Zone(), "150.mpd.test")
	}
}

// Guessing an identity is worse than refusing to start.
func TestCurrentRefusesRatherThanDefaulting(t *testing.T) {
	cases := map[string]string{
		"not an mpd host": "debian\n",
		"empty":           "\n",
		"not a number":    "mpd-abc\n",
		"out of range":    "mpd-999\n",
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			setHostname(t, body)
			if _, err := Current(); err == nil {
				t.Fatal("Current() = nil error, want refusal")
			}
		})
	}
}
