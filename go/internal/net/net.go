// Package net is the single source of truth for mpd's addressing.
// Each VM owns one /24 and one DNS zone, both keyed on the VM's id from
// its hostname (mpd-<NNN>). See docs/networking.md.
package net

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// RootDomain is the DNS root mpd owns, shared by every VM. Use it only
// for VM-independent concerns; names on this VM belong under Zone.
const RootDomain = "mpd.test"

// SubnetPrefix is the first two octets of the container address space.
// 10.163.0.0/16 is reserved by mpd in aggregate; each VM takes one /24.
const SubnetPrefix = "10.163"

// Host octets with a fixed meaning inside every VM's /24.
const (
	// HostGateway is the podman bridge: the VM itself. The resolver,
	// caddy and `mpd --web` answer here.
	HostGateway = 1
	// HostProjects is the VM's second address on the bridge, where the
	// project caddy serves every project vhost. Kept off the gateway so
	// project traffic never reaches the infra ports. Octets 3-6 are
	// unassigned.
	HostProjects = 2
)

// AllocRange is the slice of the subnet podman's IPAM may hand out. It
// starts above the octets the VM holds on the bridge itself.
func (n Net) AllocRange() string {
	return fmt.Sprintf("%s.%s.%d/24", SubnetPrefix, n.label, DBHostFirst)
}

// DB containers take the lowest free octet in this range, pinned at
// create time; vacated slots are reusable.
const (
	DBHostFirst = 10
	DBHostLast  = 99
)

// Extra service containers (mailpit, adminer, selenium, …) live in this
// range; each service descriptor pins its own octet.
const (
	ServiceHostFirst = 100
	ServiceHostLast  = 199
)

// Net answers every addressing question for one VM.
type Net struct {
	octet int
	label string
}

// New builds a Net for a VM id. Valid ids are 100–254; the value doubles
// as the third octet of the VM's /24 (see docs/networking.md).
func New(octet int) (Net, error) {
	if octet < 100 || octet > 254 {
		return Net{}, fmt.Errorf("VM id %d is not in the managed range 100–254", octet)
	}
	return Net{octet: octet, label: strconv.Itoa(octet)}, nil
}

// Current builds the Net for this VM from its hostname (mpd-<NNN>).
// A malformed hostname is an error, never a default: every address mpd
// composes depends on the id.
func Current() (Net, error) {
	id := VMIDFromHostname(readHostname())
	if id == "" {
		return Net{}, fmt.Errorf(
			"hostname is not of the form mpd-<NNN>, so the VM id cannot be derived.\n" +
				"Set it, then re-run the prepare script on the VM:\n" +
				"    sudo hostnamectl set-hostname mpd-<NNN>\n" +
				"    bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/setup/mpd-prepare-adopt.sh)")
	}
	octet, err := strconv.Atoi(id)
	if err != nil || strconv.Itoa(octet) != id {
		return Net{}, fmt.Errorf("hostname mpd-%s: %q is not a plain number 100-254", id, id)
	}
	return New(octet)
}

// VMIDFromHostname extracts the identifier from an mpd-<NNN> hostname,
// or "" if the name is not of that form.
func VMIDFromHostname(raw string) string {
	host := strings.TrimSpace(raw)
	// Strip any FQDN form: only the short name carries the identifier.
	host, _, _ = strings.Cut(host, ".")
	id, found := strings.CutPrefix(host, "mpd-")
	if !found {
		return ""
	}
	return id
}

// readHostname returns the VM's short hostname. /etc/hostname is the
// authority on Debian; $MPD_HOSTNAME_FILE overrides it for tests, and
// os.Hostname() is the last-resort fallback.
func readHostname() string {
	path := os.Getenv("MPD_HOSTNAME_FILE")
	if path == "" {
		path = "/etc/hostname"
	}
	if body, err := os.ReadFile(path); err == nil {
		return string(body)
	}
	h, _ := os.Hostname()
	return h
}

// VMID is the VM's three-digit id ("150").
func (n Net) VMID() string { return n.label }

// Octet is the third octet of this VM's subnet, equal to its id.
func (n Net) Octet() int { return n.octet }

// Zone is this VM's DNS zone — the suffix every mpd-managed name ends
// with, and the apex that resolves to the portal. e.g. "150.mpd.test".
func (n Net) Zone() string { return n.label + "." + RootDomain }

// Subnet is this VM's container subnet in CIDR form, as passed to
// `podman network create`. e.g. "10.163.150.0/24".
func (n Net) Subnet() string {
	return fmt.Sprintf("%s.%d.0/24", SubnetPrefix, n.octet)
}

// IP composes a container address from its host octet.
// e.g. IP(HostProjects) on VM 150 → "10.163.150.2".
func (n Net) IP(host int) string {
	return fmt.Sprintf("%s.%d.%d", SubnetPrefix, n.octet, host)
}

// Gateway is the podman bridge address — the VM itself, as containers
// see it.
func (n Net) Gateway() string { return n.IP(HostGateway) }

// HostOctet returns the host octet of addr when addr is inside this VM's
// /24, and false otherwise. Used when scanning live containers for
// allocated slots: an address on another subnet must not consume one.
func (n Net) HostOctet(addr string) (int, bool) {
	parts := strings.Split(addr, ".")
	if len(parts) != 4 {
		return 0, false
	}
	if parts[0]+"."+parts[1] != SubnetPrefix {
		return 0, false
	}
	third, err := strconv.Atoi(parts[2])
	if err != nil || third != n.octet {
		return 0, false
	}
	host, err := strconv.Atoi(parts[3])
	if err != nil {
		return 0, false
	}
	return host, true
}

// Contains reports whether addr sits inside this VM's /24.
func (n Net) Contains(addr string) bool {
	_, ok := n.HostOctet(addr)
	return ok
}

// Host qualifies an unqualified name into this VM's zone.
// e.g. Host("moodle45") on VM 150 → "moodle45.150.mpd.test".
func (n Net) Host(name string) string { return name + "." + n.Zone() }

// Service names an extra service container:
// Service("adminer") → "adminer.svc.<zone>".
func (n Net) Service(name string) string { return n.Host(name + ".svc") }

// DB names a database container: DB("pg17") → "pg17.db.<zone>".
func (n Net) DB(name string) string { return n.Host(name + ".db") }

// VMServiceRecord is the diagnostic record dnsmasq serves with the VM's
// own LAN IP rather than a container address, letting the host-side
// orchestrator confirm which VM answered. ("vm" is a reserved project
// name for this reason.)
func (n Net) VMServiceRecord() string { return n.Host("vm") }

// IsInZone reports whether name is this VM's zone apex or a name beneath
// it — i.e. something mpd may issue a certificate and a DNS record for.
// A name in another VM's zone is not, which is what stops a stray URL
// from being given a local cert here.
func (n Net) IsInZone(name string) bool {
	return name == n.Zone() || strings.HasSuffix(name, "."+n.Zone())
}
