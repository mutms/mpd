// Package net is the single source of truth for mpd's addressing: the
// container subnet and the DNS zone, both derived from the VM's id.
//
// # Model
//
// Each VM owns one /24 and one DNS zone, both keyed on the VM's id (read
// from its hostname, mpd-<NNN>): VM 150
// serves 10.163.150.0/24 and the zone 150.mpd.test. Ids run 001–254 as
// zero-padded identifiers. The host part of an address never varies — the
// VM itself is always .1, adminer always .6, runtimes always .100+ — only
// the third octet moves, and it always equals the VM id. That is what lets
// a workstation reach several VMs at once. See docs/NETWORKING.md.
//
// # Why Net is a value, not a global
//
// Identity is a value, not process-wide cached state: tests construct Net
// directly, and only the command layer calls Current to read the running
// VM's hostname.
package net

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// RootDomain is the DNS root mpd owns, shared by every VM. It is what the
// CA is name-constrained to, which is why one CA covers every VM's zone
// without change. Use it only for CA-level and resolver-level concerns
// that are deliberately VM-independent; anything naming a host on *this*
// VM belongs under Zone.
const RootDomain = "mpd.test"

// SubnetPrefix is the first two octets of the container address space.
// 10.163.0.0/16 is reserved by mpd in aggregate; each VM takes one /24.
const SubnetPrefix = "10.163"

// Host octets with a fixed meaning inside every VM's /24.
const (
	// HostGateway is the podman bridge: the VM itself. Everything mpd
	// serves from the VM rather than from a container answers here — the
	// resolver, caddy, and `mpd --web` behind it.
	HostGateway = 1
	// 3, 4 and 5 are unassigned. Each was a container that no longer
	// exists: 3 was dnsmasq, now a systemd unit on the VM listening on
	// the gateway; 4 was the portal, now `mpd --web` behind caddy on the
	// gateway; 5 was fileaccess, deleted outright once /srv was mounted
	// on the VM.
	HostAdminer = 6
)

// DB containers take the lowest free octet in this range, pinned at
// create time; vacated slots are reusable.
const (
	DBHostFirst = 30
	DBHostLast  = 99
)

// FirstRuntimeHost is where runtimes start (php=.100, node=.101,
// util=.102); each runtime's configuration.json names its own octet.
const FirstRuntimeHost = 100

// Net answers every addressing question for one VM.
type Net struct {
	octet int
	label string
}

// New builds a Net for a VM id. Valid ids are 1–254: the id is a zero-padded
// three-digit identifier (mpd-001), and its value doubles as the third octet
// of the VM's /24. mpd-virt carves this range into per-backend blocks; mpd
// itself only cares that the id names a legal octet.
func New(octet int) (Net, error) {
	if octet < 1 || octet > 254 {
		return Net{}, fmt.Errorf("VM id %d is not in the managed range 001–254", octet)
	}
	return Net{octet: octet, label: fmt.Sprintf("%03d", octet)}, nil
}

// Current builds the Net for this VM by deriving its id from the
// hostname (mpd-<NNN>) — the single source of truth for identity. The
// hostname is what the hypervisor-side prep set, what the user sees in
// their prompt, and what a re-imaged VM changes.
//
// A hostname that is not of the form mpd-<NNN> is an error rather than a
// default: every address and name mpd composes depends on the id, so
// guessing means building the wrong subnet or answering for another VM's
// zone. The message names the fix.
func Current() (Net, error) {
	id := VMIDFromHostname(readHostname())
	if id == "" {
		return Net{}, fmt.Errorf(
			"hostname is not of the form mpd-<NNN>, so the VM id cannot be derived.\n" +
				"Set it, then re-run the prepare script on the VM:\n" +
				"    sudo hostnamectl set-hostname mpd-<NNN>\n" +
				"    bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/setup/mpd-prepare-takeover.sh)")
	}
	octet, err := strconv.Atoi(id)
	if err != nil {
		return Net{}, fmt.Errorf("hostname mpd-%s: %q is not a number", id, id)
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

// VMID is the VM's 3-digit id, zero-padded ("022", "150").
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
// e.g. IP(HostAdminer) on VM 150 → "10.163.150.6".
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

// Service names an mpd service: Service("portal") → "portal.service.<zone>".
func (n Net) Service(name string) string { return n.Host(name + ".service") }

// Runtime names a runtime: Runtime("php") → "php.runtime.<zone>".
func (n Net) Runtime(name string) string { return n.Host(name + ".runtime") }

// RuntimeAlias is the short SSH alias for a runtime:
// RuntimeAlias("php") on VM 130 → "mpd-130-php".
//
// Not a DNS name — nothing resolves it. It is the alias
// vm.EnsureSSHConfig writes into ~/.ssh/config, and it lives here
// because it is composed from the VM id and so belongs with every other
// name keyed on it.
//
// It is also, not by coincidence, the runtime container's own hostname
// (the container is that name plus "-main"), so the prompt after `ssh
// mpd-130-php` echoes what was typed. The two are composed
// independently; this is a convention worth keeping, not a dependency.
func (n Net) RuntimeAlias(name string) string { return "mpd-" + n.label + "-" + name }

// DB names a database container: DB("pg17") → "pg17.db.<zone>".
func (n Net) DB(name string) string { return n.Host(name + ".db") }

// VMServiceRecord is the diagnostic record dnsmasq serves with the VM's
// own LAN IP rather than a container address, letting the host-side
// orchestrator confirm which VM answered.
func (n Net) VMServiceRecord() string { return n.Host("vm.service") }

// IsInZone reports whether name is this VM's zone apex or a name beneath
// it — i.e. something mpd may issue a certificate and a DNS record for.
// A name in another VM's zone is not, which is what stops a stray URL
// from being given a local cert here.
func (n Net) IsInZone(name string) bool {
	return name == n.Zone() || strings.HasSuffix(name, "."+n.Zone())
}
