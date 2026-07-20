// Package service is the registry of mpd's always-on infra services.
//
// One descriptor per service, holding everything discoverability needs:
// container name, host octet, DNS name, and the access hint shown to the
// developer. Addresses and names are composed from internal/net, so a
// descriptor is correct on every VM without change.
package service

import (
	"fmt"

	"github.com/mutms/mpd/go/internal/net"
)

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
	// accessHint renders the human-facing "how do I reach this" column.
	accessHint func(n net.Net) string
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
			Name:      "portal",
			Container: "mpd-service-portal",
			HostOctet: net.HostPortal,
			// The portal is the zone apex, not a *.service name.
			dns: func(n net.Net) string { return n.Zone() },
			accessHint: func(n net.Net) string {
				return fmt.Sprintf("https://%s/", n.Zone())
			},
		},
		{
			Name:      "fileaccess",
			Container: "mpd-service-fileaccess",
			HostOctet: net.HostFileaccess,
			accessHint: func(n net.Net) string {
				return fmt.Sprintf("ssh / scp at %s (pubkey-only, internal)", n.Service("fileaccess"))
			},
		},
		{
			Name:      "adminer",
			Container: "mpd-service-adminer",
			HostOctet: net.HostAdminer,
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

// AccessHint is the human-facing "how do I reach this" string.
func (d Descriptor) AccessHint(n net.Net) string { return d.accessHint(n) }

// Find returns the descriptor with the given name.
func Find(name string) (Descriptor, bool) {
	for _, d := range All() {
		if d.Name == name {
			return d, true
		}
	}
	return Descriptor{}, false
}
