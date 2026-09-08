// Package service is the registry and lifecycle framework for optional
// extra service containers (mailpit, adminer, selenium). Services live
// in internal/services and self-register from an init(); adding one is a
// new file there, never an edit here. They are HTTP-only, on their own
// address in the service range; see docs/networking.md.
//
// A service is one container, or — when PodContainers is set — a pod of
// several containers sharing one address and localhost (authentik). The
// pod path lives in pod.go; the single-container path in lifecycle.go.
package service

import (
	"context"
	"fmt"
	"io"
	"sort"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
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
	// PodContainers, when set, makes this service a pod of several
	// containers instead of one. The pod holds the service IP and DNS
	// name; its containers share localhost. Image, BuildContext, Volume,
	// VolumePath and RunArgs on the Service itself are then ignored.
	PodContainers []PodContainer
	// TLS, when true, also publishes the service over HTTPS through the
	// project frontdoor (mpd-caddy on .2) with an mpd-signed cert, at the
	// sibling name <name>.caddy.<zone>. <name>.svc.<zone> is unaffected —
	// it stays a direct route to the service's own address, for non-HTTP
	// protocols (LDAP, SMTP) and raw access. See docs/architecture.md.
	TLS bool
	// FrontdoorH2C makes the frontdoor reach the service over cleartext
	// HTTP/2 (h2c) instead of HTTP/1.1. Needed by gRPC backends that only
	// speak HTTP/2 behind a TLS-terminating proxy (Zitadel). TLS must also
	// be set.
	FrontdoorH2C bool
	// PostStart, when set, runs after the service is up and its TLS meta
	// written. It is the service's chance to do work that needs the
	// service already running — authentik provisions and launches its
	// LDAP outpost here. It must be idempotent: every start and reconcile
	// runs it. A returned error is reported, not fatal to the start.
	PostStart func(ctx context.Context, out io.Writer, s Service, n net.Net, p *podman.Client) error
}

// PodContainer is one container inside a pod service.
type PodContainer struct {
	// Suffix names the container: mpd-svc-<service>-<suffix>.
	Suffix string
	// Image is pulled; pod containers do not build from a context.
	Image string
	// Args is the command and its arguments, after the image.
	Args []string
	// RunArgs are extra `podman run` arguments (env vars, flags).
	RunArgs []string
	// Volume, when non-empty, is a named volume mounted at VolumePath.
	Volume     string
	VolumePath string
	// Primary marks the container that serves the service Port and
	// carries the mpd.name=<service> label the status views key on.
	Primary bool
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

// CaddyDNS is the frontdoor name for a TLS service:
// <name>.caddy.<zone>, resolving to mpd-caddy (.2), which terminates TLS
// and reverse-proxies to the service. <name>.svc.<zone> stays a direct
// route to the service's own address for non-HTTP protocols.
func (s Service) CaddyDNS(n net.Net) string { return n.Caddy(s.Name) }

// Upstream is the service's own HTTP address, <ip>:<port> — what the
// frontdoor reverse-proxies to for a TLS service.
func (s Service) Upstream(n net.Net) string {
	return fmt.Sprintf("%s:%d", s.IP(n), s.Port)
}

// AccessHint is the human-facing URL: HTTPS via the frontdoor name for a
// TLS service, else plain HTTP on the service's own address and port.
func (s Service) AccessHint(n net.Net) string {
	if s.TLS {
		return fmt.Sprintf("https://%s/", s.CaddyDNS(n))
	}
	return fmt.Sprintf("http://%s:%d/", s.DNS(n), s.Port)
}

// IsPod reports whether this service is a pod of several containers.
func (s Service) IsPod() bool { return len(s.PodContainers) > 0 }

// PodName is the podman pod name for a pod service: mpd-svc-<name>.
func (s Service) PodName() string { return "mpd-svc-" + s.Name }

// Volumes lists every named volume this service owns, so Purge can
// reclaim them all: the Service's own volume plus each pod container's.
func (s Service) Volumes() []string {
	var out []string
	if s.Volume != "" {
		out = append(out, s.Volume)
	}
	for _, c := range s.PodContainers {
		if c.Volume != "" {
			out = append(out, c.Volume)
		}
	}
	return out
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
