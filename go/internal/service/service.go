// Package service is the registry and lifecycle of mpd's OPTIONAL extra
// service containers — mailpit, adminer, seleniumv1.
//
// "Service" means exactly this: an opt-in container the developer
// enables with `mpd --service-enable=<name>`. The VM-integral pieces
// (dnsmasq, the portal) are infra, not services — they live in
// internal/vm (vm.InfraServices).
//
// Services are HTTP-only, reached at their own address in the service
// range (net.ServiceHostFirst–Last) via `http://<name>.svc.<zone>:<port>`
// — no TLS, no proxying through the VM's caddy. The laptop reaches them
// over the WireGuard overlay (which carries the whole /24) or
// SOCKS-over-SSH, both inside the trust boundary.
package service

import (
	"fmt"
	"net/url"

	"github.com/mutms/mpd/go/internal/net"
)

// Revision labels let mpd tell a container built by an older asset
// revision from a current one. Bump a service's Revision whenever its
// image, mounts, command or environment change: the label mismatch is
// what makes the next enable/reconcile rebuild the container instead of
// reporting an out-of-date one as healthy.
const RevisionLabel = "mpd.service.revision"

// Service describes one optional extra service container.
type Service struct {
	// Name is the service name ("mailpit") — the enable/disable handle,
	// the DNS label, and the mpd.name container label.
	Name string
	// HostOctet is its fixed address inside the VM's /24, from the
	// service range.
	HostOctet int
	// Image is the container image. Pulled, unless BuildContext is set.
	Image string
	// BuildContext, when non-empty, names the assets/services/<dir> the
	// image is built from instead of pulled.
	BuildContext string
	// Revision versions the built/derived container (see RevisionLabel).
	Revision string
	// Volume, when non-empty, is a named podman volume mounted at
	// VolumePath — the data that survives --service-uninstall and dies
	// with --service-purge.
	Volume     string
	VolumePath string
	// Port is the primary HTTP UI/API port, for links and hints.
	Port int
	// RunArgs are extra `podman run` arguments (env vars, --shm-size…).
	RunArgs []string
	// projectLinks, when set, contributes per-project dashboard links
	// (see ProjectLinks). This is the pluggable half of the portal
	// integration: the portal ranges over services and asks, instead of
	// hardcoding any service's URL scheme.
	projectLinks func(s Service, n net.Net, info ProjectInfo) []Link
}

// ProjectInfo is what a ProjectLinks hook may build links from.
type ProjectInfo struct {
	Name     string
	DBEngine string
	DBHost   string
	DBUser   string
	DBName   string
}

// Link is one per-project link a service contributes to the dashboard.
type Link struct{ Label, URL string }

// ProjectLinks returns the links this service offers for one project,
// or nil. The caller gates on the service being enabled and running and
// on the database being up — a link to a connection error is worse than
// no link.
func (s Service) ProjectLinks(n net.Net, info ProjectInfo) []Link {
	if s.projectLinks == nil {
		return nil
	}
	return s.projectLinks(s, n, info)
}

// All returns every known extra service, in registry order.
func All() []Service {
	return []Service{
		{
			// SMTP catch-all for every project. Mail is stored on a
			// volume so the inbox survives an uninstall/enable cycle.
			Name:       "mailpit",
			HostOctet:  100,
			Image:      "docker.io/axllent/mailpit:latest",
			Revision:   "1",
			Volume:     "mpd-svc-mailpit",
			VolumePath: "/data",
			Port:       8025,
			RunArgs:    []string{"-e", "MP_DATABASE=/data/mailpit.db"},
		},
		{
			// DB administration UI. Built from Debian rather than pulled:
			// the docker.io/library/adminer image is Alpine-based, and
			// libpq on musl fails to resolve multi-label hostnames like
			// `postgres-latest.db.<zone>` — which is every database name
			// mpd publishes. The symptom is an opaque
			// `SQLSTATE[08006] could not translate host name`.
			Name:         "adminer",
			HostOctet:    102,
			Image:        "localhost/mpd-adminer:latest",
			BuildContext: "adminer",
			Revision:     "8",
			Port:         8080,
			projectLinks: adminerProjectLinks,
		},
		{
			// Behat's WebDriver endpoint. Versioned name ("v1") so future
			// Moodle releases can require a different selenium alongside
			// this one. ~2 GB image — enabling announces the pull.
			Name:      "seleniumv1",
			HostOctet: 103,
			Image:     "docker.io/selenium/standalone-chromium:latest",
			Revision:  "1",
			Port:      4444,
			RunArgs: []string{
				"--shm-size=2g",
				"-e", "SE_NODE_MAX_SESSIONS=10",
				"-e", "SE_NODE_OVERRIDE_MAX_SESSIONS=true",
				"-e", "SE_SCREEN_WIDTH=1400",
				"-e", "SE_SCREEN_HEIGHT=800",
			},
		},
	}
}

// Find returns the service with the given name.
func Find(name string) (Service, bool) {
	for _, s := range All() {
		if s.Name == name {
			return s, true
		}
	}
	return Service{}, false
}

// Names lists every known service name, in registry order.
func Names() []string {
	var out []string
	for _, s := range All() {
		out = append(out, s.Name)
	}
	return out
}

// Container is the podman container name: mpd-svc-<name>.
func (s Service) Container() string { return "mpd-svc-" + s.Name }

// IP is this service's address on the given VM.
func (s Service) IP(n net.Net) string { return n.IP(s.HostOctet) }

// DNS is this service's name on the given VM: <name>.svc.<zone>.
func (s Service) DNS(n net.Net) string { return n.Service(s.Name) }

// AccessHint is the human-facing "how do I reach this" string. Plain
// HTTP at the service's own name and port — services have no TLS.
func (s Service) AccessHint(n net.Net) string {
	return fmt.Sprintf("http://%s:%d/", s.DNS(n), s.Port)
}

// adminerProjectLinks builds a prefilled Adminer link for a project's
// database.
//
// Adminer takes the driver as the parameter NAME, not a value: postgres
// is `?pgsql=<host>`, while MySQL and MariaDB are `?server=<host>`. Get
// that wrong and Adminer shows its own login form with nothing filled
// in, which looks like the link is broken rather than mistyped.
func adminerProjectLinks(s Service, n net.Net, info ProjectInfo) []Link {
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
	return []Link{{
		Label: "Adminer",
		URL:   fmt.Sprintf("http://%s:%d/?%s", s.DNS(n), s.Port, q.Encode()),
	}}
}

// commonLabels are on every service container: mpd.managed marks it as
// ours to reconcile, and the compose label groups the services together
// in Podman Desktop and `podman ps` output.
func commonLabels(name string) []string {
	return []string{
		"--label", "mpd.managed=true",
		"--label", "mpd.type=service",
		"--label", "mpd.name=" + name,
		"--label", "com.docker.compose.project=mpd-service",
	}
}
