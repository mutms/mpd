// Package service is the registry of mpd's always-on infra services.
//
// One descriptor per service, holding everything discoverability needs:
// container name, host octet, DNS name, and the access hint shown to the
// developer. Addresses and names are composed from internal/net, so a
// descriptor is correct on every VM without change.
package service

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/podman"

	"github.com/mutms/mpd/go/internal/net"
)

// Revision labels let setup tell a container built by an older mpd from
// one built by this mpd. Bump the relevant one whenever a service's
// image, mounts, command or environment change: the label mismatch is
// what makes `--vm-setup` rebuild the container instead of reporting an
// out-of-date one as healthy.
const (
	RevisionLabel      = "mpd.service.revision"
	CAFingerprintLabel = "mpd.ca.fingerprint"

	adminerRevision = "7"
	dnsmasqRevision = "9"
)

// AdminerImage is the one service image mpd builds rather than pulls.
const AdminerImage = "localhost/mpd-adminer:latest"

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

// Descriptor describes one always-on service.
type Descriptor struct {
	// Name is the short service name ("portal").
	Name string
	// Container is the podman container name.
	Container string
	// HostOctet is its address inside the VM's /24.
	HostOctet int
	// dns overrides the default "<name>.service.<zone>" when non-empty;
	// the portal answers at the zone apex instead.
	dns func(n net.Net) string
	// aliases lists every name that must resolve to this service, when
	// more than the canonical one does. Nil means just DNS().
	aliases func(n net.Net) []string
	// accessHint renders the human-facing "how do I reach this" column.
	accessHint func(n net.Net) string
	// Proxy, when set, means this service is not reached at its own
	// address: its names resolve to the portal, which terminates TLS and
	// proxies to the address below. Adminer works this way — it speaks
	// plain HTTP and has no certificate of its own.
	Proxy *PortalProxy
	// Unit names the systemd unit backing this service, for services that
	// are NOT containers. `mpd --web` runs on the VM itself, so its
	// status comes from systemd and podman has never heard of it.
	Unit string
}

// PortalProxy describes an upstream the portal reverse-proxies to.
type PortalProxy struct {
	// Scheme is the upstream protocol; empty means http.
	Scheme string
	// Port is the upstream port on the service's own address.
	Port int
}

// UpstreamURL is what the rendered vhost proxies to.
func (p PortalProxy) UpstreamURL(ip string) string {
	scheme := p.Scheme
	if scheme == "" {
		scheme = "http"
	}
	return fmt.Sprintf("%s://%s:%d", scheme, ip, p.Port)
}

// All returns every service descriptor, in registry order.
func All() []Descriptor {
	return []Descriptor{
		{
			Name:      "dnsmasq",
			Container: "mpd-service-dnsmasq",
			HostOctet: net.HostDnsmasq,
			accessHint: func(n net.Net) string {
				return fmt.Sprintf("DNS resolver (%s:53)", n.IP(net.HostDnsmasq))
			},
		},
		{
			// The status page: `mpd --web` on the VM behind the VM's own
			// Caddy, not a container. Its address is the podman bridge
			// gateway, which the laptop reaches over its static route and
			// every container reaches as its gateway.
			Name:      "portal",
			Unit:      "mpd-web.service",
			HostOctet: net.HostGateway,
			// The portal is the zone apex, not a *.service name.
			dns: func(n net.Net) string { return n.Zone() },
			// Both names answer: the apex is what a developer types,
			// portal.service.<zone> is what the uniform service naming
			// makes them expect to work.
			aliases: func(n net.Net) []string { return []string{n.Zone(), n.Service("portal")} },
			accessHint: func(n net.Net) string {
				return fmt.Sprintf("https://%s/", n.Zone())
			},
		},
		{
			Name:      "adminer",
			Container: "mpd-service-adminer",
			HostOctet: net.HostAdminer,
			Proxy:     &PortalProxy{Port: 8080},
			accessHint: func(n net.Net) string {
				return fmt.Sprintf("https://%s/", n.Service("adminer"))
			},
		},
	}
}

// IP is this service's address on the given VM.
func (d Descriptor) IP(n net.Net) string { return n.IP(d.HostOctet) }

// DNS is this service's canonical name on the given VM.
func (d Descriptor) DNS(n net.Net) string {
	if d.dns != nil {
		return d.dns(n)
	}
	return n.Service(d.Name)
}

// Aliases lists every name that must resolve to this service.
func (d Descriptor) Aliases(n net.Net) []string {
	if d.aliases != nil {
		return d.aliases(n)
	}
	return []string{d.DNS(n)}
}

// AccessHint is the human-facing "how do I reach this" string.
func (d Descriptor) AccessHint(n net.Net) string { return d.accessHint(n) }

// DNSRecord is one name mpd publishes for a service.
type DNSRecord struct {
	Host string
	IP   string
}

// DNSRecords is every service name mpd publishes, in registry order.
//
// A proxied service's names point at the PORTAL's address, not its own:
// the portal is what terminates TLS for it, so resolving straight to the
// service would reach a plain-HTTP port with no certificate.
func DNSRecords(n net.Net) []DNSRecord {
	var out []DNSRecord
	// Proxied services resolve to whatever terminates their TLS, which is
	// the portal's own address — read from the registry rather than a
	// hardcoded octet, so moving the portal moves them with it.
	portalIP := ""
	if d, ok := Find("portal"); ok {
		portalIP = d.IP(n)
	}
	for _, d := range All() {
		target := d.IP(n)
		if d.Proxy != nil {
			target = portalIP
		}
		for _, alias := range d.Aliases(n) {
			out = append(out, DNSRecord{Host: alias, IP: target})
		}
	}
	return out
}

// Proxied returns the services the portal reverse-proxies for.
func Proxied() []Descriptor {
	var out []Descriptor
	for _, d := range All() {
		if d.Proxy != nil {
			out = append(out, d)
		}
	}
	return out
}

// Find returns the descriptor with the given name.
func Find(name string) (Descriptor, bool) {
	for _, d := range All() {
		if d.Name == name {
			return d, true
		}
	}
	return Descriptor{}, false
}

// --- Lifecycle --------------------------------------------------------

// Start starts a service container that already exists.
//
// Deliberately does NOT create a missing one: `--vm-start` is the daily
// path and must stay fast and predictable, while creating a service
// means building images and generating certs. A missing container means
// setup has not run, and saying so is more useful than silently doing
// setup's job.
// Every message names the service the same way — "Service: <name>",
// "<name> running.", "<name> already running." — so a scrolling setup or
// start log reads uniformly.
func Start(ctx context.Context, out io.Writer, d Descriptor, n net.Net, p *podman.Client) error {
	fmt.Fprintf(out, "\n\033[1m==> Service: %s\033[0m\n", d.Name)
	if !p.Exists(ctx, d.Container) {
		return fmt.Errorf("%s not found. Run: mpd --vm-setup", d.Container)
	}
	if p.Running(ctx, d.Container) {
		fmt.Fprintf(out, "\033[1;32m✓ %s already running.\033[0m\n", d.Name)
		return nil
	}
	if code, err := p.Start(ctx, d.Container); err != nil || code != 0 {
		return fmt.Errorf("Failed to start %s. Run: mpd --vm-setup", d.Container)
	}
	fmt.Fprintf(out, "\033[1;32m✓ %s running.\033[0m\n", d.Name)
	return nil
}
