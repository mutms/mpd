package vm

import (
	"os"
	"strings"
	"testing"
)

func read(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestVMIDFromHostname(t *testing.T) {
	cases := map[string]string{
		"mpd-150":                 "150",
		"mpd-000":                 "000",
		"mpd-150.local\n":         "150",
		"  mpd-254  ":             "254",
		"workstation":             "",
		"":                        "",
		"not-mpd-150":             "",
		"mpd-150.some.domain.tld": "150",
	}
	for hostname, want := range cases {
		if got := VMIDFromHostname(hostname); got != want {
			t.Errorf("VMIDFromHostname(%q) = %q, want %q", hostname, got, want)
		}
	}
}

func TestParseOSRelease(t *testing.T) {
	got := ParseOSRelease(`PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
ID=debian
VERSION_CODENAME=trixie
# a comment line with no equals sign
`)
	if got.ID != "debian" || got.Codename != "trixie" {
		t.Fatalf("got %+v", got)
	}
}

// A file that names neither key must not read as a supported host by
// accident: the empty values are what RequireSupportedHost rejects on.
func TestParseOSReleaseMissingKeys(t *testing.T) {
	got := ParseOSRelease("NAME=\"Something Else\"\n")
	if got.ID != "" || got.Codename != "" {
		t.Fatalf("got %+v, want zero value", got)
	}
}

// Keys mpd does not own must survive a rewrite: bootstrap scripts write
// MPD_NETWORK_* into the same file, and losing them would break the next
// boot's networking.
func TestWritePlatformPreservesForeignKeys(t *testing.T) {
	path := t.TempDir() + "/platform.env"

	if err := os.WriteFile(path, []byte(`MPD_PLATFORM=managed
MPD_VM_IP=10.211.55.150
MPD_VM_ID=150
MPD_NETWORK_IFACE=enp0s5
MPD_NETWORK_GATEWAY=10.211.55.1
`), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := WritePlatformTo(path, PlatformIdentity{
		Platform: PlatformManaged, VMIP: "10.211.55.180", VMID: "180",
	}); err != nil {
		t.Fatal(err)
	}

	body := read(t, path)
	for _, want := range []string{
		"MPD_VM_ID=180",
		"MPD_VM_IP=10.211.55.180",
		"MPD_NETWORK_IFACE=enp0s5",
		"MPD_NETWORK_GATEWAY=10.211.55.1",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("rewritten file lost %q:\n%s", want, body)
		}
	}
	// The old values must be gone, not merely outnumbered.
	if strings.Contains(body, "MPD_VM_ID=150") {
		t.Errorf("stale VM ID survived:\n%s", body)
	}
}

func TestLoadPlatformRejectsUnknownPlatform(t *testing.T) {
	path := t.TempDir() + "/platform.env"
	if err := os.WriteFile(path, []byte("MPD_PLATFORM=kubernetes\nMPD_VM_ID=150\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadPlatformFrom(path); err == nil {
		t.Fatal("an unknown MPD_PLATFORM was accepted")
	}
}

func TestLoadPlatformRoundTrip(t *testing.T) {
	path := t.TempDir() + "/platform.env"

	want := PlatformIdentity{Platform: PlatformSandbox, VMIP: "", VMID: "000"}
	if err := WritePlatformTo(path, want); err != nil {
		t.Fatal(err)
	}
	got, err := LoadPlatformFrom(path)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("round trip = %+v, want %+v", got, want)
	}
}
