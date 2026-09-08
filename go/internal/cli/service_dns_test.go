package cli

import (
	"testing"

	"github.com/mutms/mpd/go/internal/net"
)

// Every registered service's .svc name resolves straight to its own
// address, published in advance regardless of install state; a TLS
// service additionally gets a .caddy sibling at the frontdoor (.2).
func TestServiceDNSRecordsTLS(t *testing.T) {
	n, err := net.New(222)
	if err != nil {
		t.Fatalf("net.New: %v", err)
	}

	got := map[string]string{}
	for _, r := range ServiceDNSRecords(n) {
		got[r.Names[0]] = r.IP
	}

	want := map[string]string{
		"authentik.svc.222.mpd.test":   "10.163.222.101",       // pod, direct
		"authentik.caddy.222.mpd.test": n.IP(net.HostProjects), // frontdoor
		"mailpit.svc.222.mpd.test":     "10.163.222.100",       // pod, direct
	}
	for name, ip := range want {
		if got[name] != ip {
			t.Errorf("%s = %q, want %q", name, got[name], ip)
		}
	}
	// A plain-HTTP service has no frontdoor name.
	if _, ok := got["mailpit.caddy.222.mpd.test"]; ok {
		t.Error("plain-HTTP service must not get a .caddy record")
	}
}
