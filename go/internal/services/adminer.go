package services

import (
	"fmt"
	"net/url"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/service"
)

// adminer — database administration web UI. Built from Debian rather than
// pulled: the docker.io/library/adminer image is Alpine-based, and libpq on
// musl fails to resolve multi-label hostnames like `postgres-latest.db.<zone>`
// — which is every database name mpd publishes. The symptom is an opaque
// `SQLSTATE[08006] could not translate host name`.
func init() {
	service.Register(service.Service{
		Name:         "adminer",
		HostOctet:    102,
		Image:        "localhost/mpd-adminer:latest",
		BuildContext: "adminer",
		Revision:     "8",
		Port:         8080,
		LinkFn:       adminerProjectLinks,
	})
}

// adminerProjectLinks builds a prefilled Adminer link for a project's
// database.
//
// Adminer takes the driver as the parameter NAME, not a value: postgres
// is `?pgsql=<host>`, while MySQL and MariaDB are `?server=<host>`. Get
// that wrong and Adminer shows its own login form with nothing filled
// in, which looks like the link is broken rather than mistyped.
func adminerProjectLinks(s service.Service, n net.Net, info service.ProjectInfo) []service.Link {
	if info.DBHost == "" {
		return nil
	}
	driver := "server"
	if info.DBEngine == "postgres" {
		driver = "pgsql"
	}
	q := url.Values{}
	q.Set(driver, info.DBHost)
	q.Set("username", info.DBUser)
	if info.DBName != "" {
		q.Set("db", info.DBName)
	}
	return []service.Link{{
		Label: "Adminer",
		URL:   fmt.Sprintf("http://%s:%d/?%s", s.DNS(n), s.Port, q.Encode()),
	}}
}
