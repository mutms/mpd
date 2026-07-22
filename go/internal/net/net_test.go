package net

import (
	"os"
	"path/filepath"
	"strings"
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
		{150, "150.mpd.test", "10.163.150.0/24", "10.163.150.1"},
		{222, "222.mpd.test", "10.163.222.0/24", "10.163.222.1"},
		// Sandbox is not a special case — just the zeroth VM. It keeps
		// the 10.163.0.0/24 every VM shared before per-VM addressing.
		{0, "000.mpd.test", "10.163.0.0/24", "10.163.0.1"},
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

func TestVMIDIsZeroPadded(t *testing.T) {
	for octet, want := range map[int]string{0: "000", 22: "022", 150: "150"} {
		if got := mustNew(t, octet).VMID(); got != want {
			t.Errorf("New(%d).VMID() = %q, want %q", octet, got, want)
		}
	}
}

func TestNewRejectsOutOfRange(t *testing.T) {
	for _, octet := range []int{-1, 255, 999} {
		if _, err := New(octet); err == nil {
			t.Errorf("New(%d) = nil error, want rejection", octet)
		}
	}
}

func TestNaming(t *testing.T) {
	n := mustNew(t, 150)
	tests := map[string]string{
		n.Host("moodle45"):  "moodle45.150.mpd.test",
		n.Service("portal"): "portal.service.150.mpd.test",
		n.Runtime("php"):    "php.runtime.150.mpd.test",
		n.DB("pg17"):        "pg17.db.150.mpd.test",
		n.VMServiceRecord(): "vm.service.150.mpd.test",
	}
	for got, want := range tests {
		if got != want {
			t.Errorf("got %q, want %q", got, want)
		}
	}
}

// The zone apex resolves to the portal; the bare root domain must not
// resolve at all, because with two VMs up it could only mean one of them.
func TestIsInZone(t *testing.T) {
	n := mustNew(t, 150)
	in := []string{
		"150.mpd.test",
		"moodle45.150.mpd.test",
		"behat.moodle45.150.mpd.test",
		"php.runtime.150.mpd.test",
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
		// Suffix matching must not be fooled by a name that merely ends
		// in the same characters without the dot boundary.
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
	for _, addr := range []string{"192.168.1.1", "10.163.150", "", "10.163.150.x", "not an ip"} {
		if _, ok := n.HostOctet(addr); ok {
			t.Errorf("HostOctet(%q) = ok, want not ok", addr)
		}
	}
	if !n.Contains("10.163.150.4") {
		t.Error("Contains(own portal IP) = false, want true")
	}
}

func writePlatformEnv(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "platform.env")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("writing fixture: %v", err)
	}
	return path
}

func TestLoad(t *testing.T) {
	path := writePlatformEnv(t, `# mpd platform identity
MPD_PLATFORM=managed
MPD_VM_IP=10.211.55.150
MPD_VM_ID=150
`)
	n, err := Load(path)
	if err != nil {
		t.Fatalf("Load() failed: %v", err)
	}
	if n.Zone() != "150.mpd.test" {
		t.Errorf("Zone() = %q, want %q", n.Zone(), "150.mpd.test")
	}
}

func TestLoadSandboxKeepsLeadingZeros(t *testing.T) {
	path := writePlatformEnv(t, "MPD_VM_ID=000\n")
	n, err := Load(path)
	if err != nil {
		t.Fatalf("Load() failed: %v", err)
	}
	if n.VMID() != "000" || n.Subnet() != "10.163.0.0/24" {
		t.Errorf("sandbox: VMID=%q Subnet=%q", n.VMID(), n.Subnet())
	}
}

// Guessing an identity is worse than refusing to start: it means either
// building the wrong subnet or answering for another VM's zone.
func TestLoadRefusesRatherThanDefaulting(t *testing.T) {
	cases := map[string]string{
		"missing key":  "MPD_PLATFORM=managed\n",
		"empty value":  "MPD_VM_ID=\n",
		"not a number": "MPD_VM_ID=abc\n",
		"out of range": "MPD_VM_ID=999\n",
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := Load(writePlatformEnv(t, body)); err == nil {
				t.Fatal("Load() = nil error, want refusal")
			}
		})
	}
}

func TestLoadMissingFileNamesTheFix(t *testing.T) {
	_, err := Load(filepath.Join(t.TempDir(), "absent.env"))
	if err == nil {
		t.Fatal("Load() = nil error for a missing file")
	}
	if !strings.Contains(err.Error(), "30-networking.sh") {
		t.Errorf("err = %v, want it to name the bootstrap step that fixes it", err)
	}
}
