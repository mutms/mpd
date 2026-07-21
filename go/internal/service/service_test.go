package service

import (
	"testing"

	"github.com/mutms/mpd/go/internal/net"
)

func testNet(t *testing.T, octet int) net.Net {
	t.Helper()
	n, err := net.New(octet)
	if err != nil {
		t.Fatalf("net.New(%d): %v", octet, err)
	}
	return n
}

func TestNamesAndAddresses(t *testing.T) {
	n := testNet(t, 150)
	want := map[string]struct{ ip, dns string }{
		"dnsmasq": {"10.163.150.3", "dnsmasq.service.150.mpd.test"},
		"portal":  {"10.163.150.1", "150.mpd.test"}, // apex on the gateway, not *.service
		"adminer": {"10.163.150.6", "adminer.service.150.mpd.test"},
	}
	for name, exp := range want {
		d, ok := Find(name)
		if !ok {
			t.Fatalf("Find(%q) not found", name)
		}
		if got := d.IP(n); got != exp.ip {
			t.Errorf("%s IP = %q, want %q", name, got, exp.ip)
		}
		if got := d.DNS(n); got != exp.dns {
			t.Errorf("%s DNS = %q, want %q", name, got, exp.dns)
		}
	}
}

// The portal answers at the zone apex — the one service whose name is not
// <name>.service.<zone>. Regressing this makes https://<id>.mpd.test/
// stop resolving to the portal.
func TestPortalIsTheZoneApex(t *testing.T) {
	for _, octet := range []int{0, 150, 222} {
		n := testNet(t, octet)
		d, _ := Find("portal")
		if d.DNS(n) != n.Zone() {
			t.Errorf("VM %d: portal DNS = %q, want zone apex %q", octet, d.DNS(n), n.Zone())
		}
	}
}

func TestDescriptorsAreVMIndependent(t *testing.T) {
	a, b := testNet(t, 150), testNet(t, 222)
	for _, d := range All() {
		if d.IP(a) == d.IP(b) {
			t.Errorf("%s has the same IP on two VMs (%s)", d.Name, d.IP(a))
		}
		if d.AccessHint(a) == d.AccessHint(b) {
			t.Errorf("%s has a VM-independent access hint: %q", d.Name, d.AccessHint(a))
		}
	}
}

func TestFindUnknown(t *testing.T) {
	if _, ok := Find("nope"); ok {
		t.Error("Find(\"nope\") = ok, want not found")
	}
}
