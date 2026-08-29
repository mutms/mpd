// Package service is the registry and lifecycle framework for optional
// extra service containers (mailpit, adminer, selenium). Services live
// in internal/services and self-register from an init(); adding one is a
// new file there, never an edit here. They are HTTP-only, on their own
// address in the service range; see docs/networking.md.
package service

import (
	"fmt"
	"sort"

	"github.com/mutms/mpd/go/internal/net"
)

// RevisionLabel marks the asset revision a container was built from.
// Bump a service's Revision when its image, mounts, command or
// environment change, so the next reconcile rebuilds the container.
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
	// ProjectLinks); the portal asks instead of hardcoding URL schemes.
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
// or nil. The caller gates on the service and database being up.
func (s Service) ProjectLinks(n net.Net, info ProjectInfo) []Link {
	if s.LinkFn == nil {
		return nil
	}
	return s.LinkFn(s, n, info)
}

var registry []Service

// Register records one service, called from a service file's init().
// A duplicate name or an out-of-range octet is a programming error, so
// it panics at startup.
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

// All returns every registered service, ordered by HostOctet so the
// order does not depend on file-init order.
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

// AccessHint is the human-facing URL: plain HTTP, services have no TLS.
func (s Service) AccessHint(n net.Net) string {
	return fmt.Sprintf("http://%s:%d/", s.DNS(n), s.Port)
}

// commonLabels go on every service container.
func commonLabels(name string) []string {
	return []string{
		"--label", "mpd.managed=true",
		"--label", "mpd.type=service",
		"--label", "mpd.name=" + name,
		"--label", "com.docker.compose.project=mpd-service",
	}
}
