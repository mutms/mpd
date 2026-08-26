// Package service is the registry and lifecycle framework the individual
// services plug into: the Service descriptor, the registry, the address/label
// helpers, and the container lifecycle (Start/Stop/Uninstall/Purge). The
// services themselves live in internal/services and self-register — one file
// each, registering from an init() via Register — so adding a service is a new
// file there, never an edit to a central list here. Consumers blank-import
// internal/services once (from the cli layer) to pull the registrations in,
// exactly as internal/backend is fed by internal/backends.
//
// "Service" means exactly this: an opt-in container a project pulls in via
// MPD_REQUIRE_SERVICES (started on demand, like its database) or the developer
// drives directly with `mpd --service-start=<name>`. The VM-integral pieces
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
	"sort"

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
	// Name is the service name ("mailpit") — the start/stop handle,
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
	// LinkFn, when set, contributes per-project dashboard links (see
	// ProjectLinks). This is the pluggable half of the portal integration:
	// the portal ranges over services and asks, instead of hardcoding any
	// service's URL scheme. Exported so a service in internal/services can
	// set it when it registers.
	LinkFn func(s Service, n net.Net, info ProjectInfo) []Link
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
	if s.LinkFn == nil {
		return nil
	}
	return s.LinkFn(s, n, info)
}

// registry holds every service that registered itself from an init(). Each
// service lives in its own file and calls Register there, so the set grows by
// adding a file — never by editing a list here.
var registry []Service

// Register records one service, called from a service file's init(). A
// duplicate name or an octet outside the service range is a programming error
// in a service file, so it panics at startup rather than shipping a broken
// registry.
func Register(s Service) {
	if s.HostOctet < net.ServiceHostFirst || s.HostOctet > net.ServiceHostLast {
		panic(fmt.Sprintf("service %q octet %d is outside the service range %d–%d",
			s.Name, s.HostOctet, net.ServiceHostFirst, net.ServiceHostLast))
	}
	for _, existing := range registry {
		if existing.Name == s.Name {
			panic(fmt.Sprintf("service %q registered twice", s.Name))
		}
		if existing.HostOctet == s.HostOctet {
			panic(fmt.Sprintf("services %q and %q share octet %d",
				existing.Name, s.Name, s.HostOctet))
		}
	}
	registry = append(registry, s)
}

// All returns every registered service, ordered by address (HostOctet) so the
// order is stable regardless of the file-init order the compiler picks.
func All() []Service {
	out := append([]Service(nil), registry...)
	sort.Slice(out, func(i, j int) bool { return out[i].HostOctet < out[j].HostOctet })
	return out
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
