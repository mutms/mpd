package services

import (
	"strings"
	"testing"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/service"
)

func testNet(t *testing.T, octet int) net.Net {
	t.Helper()
	n, err := net.New(octet)
	if err != nil {
		t.Fatalf("net.New(%d): %v", octet, err)
	}
	return n
}

// Adminer's per-project link carries the driver as the parameter name:
// pgsql for postgres, server for mysql/mariadb.
func TestAdminerProjectLink(t *testing.T) {
	n := testNet(t, 150)
	adminer, ok := service.Find("adminer")
	if !ok {
		t.Fatal("adminer did not register")
	}

	links := adminer.ProjectLinks(n, service.ProjectInfo{
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

	mysql := adminer.ProjectLinks(n, service.ProjectInfo{
		Name: "m", DBEngine: "mysql", DBHost: "mysql-8-4.db.150.mpd.test", DBUser: "m", DBName: "m",
	})
	if !strings.Contains(mysql[0].URL, "server=mysql-8-4.db.150.mpd.test") {
		t.Errorf("mysql link %q should use the server parameter", mysql[0].URL)
	}

	if got := adminer.ProjectLinks(n, service.ProjectInfo{Name: "nodb"}); got != nil {
		t.Errorf("no database → no link, got %v", got)
	}

	// A descriptor without a LinkFn contributes nothing.
	mailpit, _ := service.Find("mailpit")
	if got := mailpit.ProjectLinks(n, service.ProjectInfo{Name: "x", DBHost: "h"}); got != nil {
		t.Errorf("mailpit should contribute no project links, got %v", got)
	}
}
