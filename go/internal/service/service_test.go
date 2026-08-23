package service

import (
	"strings"
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
		"mailpit":    {"10.163.150.100", "mailpit.svc.150.mpd.test"},
		"adminer":    {"10.163.150.102", "adminer.svc.150.mpd.test"},
		"seleniumv1": {"10.163.150.103", "seleniumv1.svc.150.mpd.test"},
	}
	for name, exp := range want {
		s, ok := Find(name)
		if !ok {
			t.Fatalf("Find(%q) not found", name)
		}
		if got := s.IP(n); got != exp.ip {
			t.Errorf("%s IP = %q, want %q", name, got, exp.ip)
		}
		if got := s.DNS(n); got != exp.dns {
			t.Errorf("%s DNS = %q, want %q", name, got, exp.dns)
		}
	}
}

// Every service must live in the service octet range — the addressing
// contract docs/networking.md documents.
func TestServicesLiveInTheServiceRange(t *testing.T) {
	for _, s := range All() {
		if s.HostOctet < net.ServiceHostFirst || s.HostOctet > net.ServiceHostLast {
			t.Errorf("%s octet %d outside the service range %d–%d",
				s.Name, s.HostOctet, net.ServiceHostFirst, net.ServiceHostLast)
		}
	}
}

// Services are HTTP-only: the access hint must never promise TLS.
func TestAccessHintsAreHTTP(t *testing.T) {
	n := testNet(t, 150)
	for _, s := range All() {
		hint := s.AccessHint(n)
		if !strings.HasPrefix(hint, "http://") {
			t.Errorf("%s access hint %q must be plain http", s.Name, hint)
		}
	}
}

func TestDescriptorsAreVMIndependent(t *testing.T) {
	a, b := testNet(t, 150), testNet(t, 222)
	for _, s := range All() {
		if s.IP(a) == s.IP(b) {
			t.Errorf("%s has the same IP on two VMs (%s)", s.Name, s.IP(a))
		}
		if s.AccessHint(a) == s.AccessHint(b) {
			t.Errorf("%s has a VM-independent access hint: %q", s.Name, s.AccessHint(a))
		}
	}
}

func TestFindUnknown(t *testing.T) {
	if _, ok := Find("nope"); ok {
		t.Error("Find(\"nope\") = ok, want not found")
	}
}

// Adminer's per-project link carries the driver as the parameter NAME —
// pgsql for postgres, server for mysql/mariadb. Getting it wrong shows
// an empty Adminer login form that looks broken rather than mistyped.
func TestAdminerProjectLink(t *testing.T) {
	n := testNet(t, 150)
	adminer, _ := Find("adminer")

	links := adminer.ProjectLinks(n, ProjectInfo{
		Name: "smoke", DBEngine: "postgres",
		DBHost: "postgres-17.db.150.mpd.test", DBUser: "smoke", DBName: "smoke",
	})
	if len(links) != 1 {
		t.Fatalf("links = %v, want one", links)
	}
	url := links[0].URL
	for _, want := range []string{
		"http://adminer.svc.150.mpd.test:8080/",
		"pgsql=postgres-17.db.150.mpd.test",
		"username=smoke",
	} {
		if !strings.Contains(url, want) {
			t.Errorf("adminer link %q should contain %q", url, want)
		}
	}

	mysql := adminer.ProjectLinks(n, ProjectInfo{
		Name: "m", DBEngine: "mysql", DBHost: "mysql-8-4.db.150.mpd.test", DBUser: "m", DBName: "m",
	})
	if !strings.Contains(mysql[0].URL, "server=mysql-8-4.db.150.mpd.test") {
		t.Errorf("mysql link %q should use the server parameter", mysql[0].URL)
	}

	if got := adminer.ProjectLinks(n, ProjectInfo{Name: "nodb"}); got != nil {
		t.Errorf("no database → no link, got %v", got)
	}

	// Services without a hook contribute nothing.
	mailpit, _ := Find("mailpit")
	if got := mailpit.ProjectLinks(n, ProjectInfo{Name: "x", DBHost: "h"}); got != nil {
		t.Errorf("mailpit should contribute no project links, got %v", got)
	}
}
