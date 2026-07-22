// Package net is the single source of truth for mpd's addressing: the
// container subnet and the DNS zone, both derived from the VM's id.
//
// Nothing outside this package should contain "10.163." or "mpd.test" as
// a literal. The Swift implementation learned this the hard way — the
// same two facts were spread across ~165 lines before Mpd.Net collected
// them.
//
// # Model
//
// Each VM owns one /24 and one DNS zone, both keyed on MPD_VM_ID: VM 150
// serves 10.163.150.0/24 and the zone 150.mpd.test; the sandbox VM is
// 000. The host part of an address never varies — the VM itself is always
// .1, adminer always .6, runtimes always .100+ — only the third octet
// moves, and it always equals the VM id. That is what lets a workstation
// reach several VMs at once. See docs/NETWORKING.md.
//
// # Why Net is a value, not a global
//
// The Swift version resolved identity into process-wide cached state,
// which made it untestable without a real /var/lib/mpd/conf/platform.env.
// Here identity is a value: tests construct Net directly, and only the
// command layer calls Load to read the real file.
package net

import (
	"bufio"
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

// PlatformEnvPath is where the VM's identity is recorded. Not under
// /srv or any container-visible path: it lives beside the CA key and is
// deliberately never bind-mounted into a container.
const PlatformEnvPath = "/var/lib/mpd/conf/platform.env"

// Net answers every addressing question for one VM.
type Net struct {
	octet int
	label string
}

// New builds a Net for a VM id. Valid ids are 0–254: 0 is the sandbox VM,
// 100–254 are managed VMs (1–99 is the hypervisor's DHCP pool).
func New(octet int) (Net, error) {
	if octet < 0 || octet > 254 {
		return Net{}, fmt.Errorf("VM id %d is not an octet in [0, 254]", octet)
	}
	return Net{octet: octet, label: fmt.Sprintf("%03d", octet)}, nil
}

// Load reads the VM id from a platform.env-shaped file and builds a Net.
//
// A missing or malformed MPD_VM_ID is an error rather than a default:
// every address and name mpd composes depends on it, so guessing means
// either silently building the wrong subnet or answering for another
// VM's zone. The message names the fix.
func Load(path string) (Net, error) {
	f, err := os.Open(path)
	if err != nil {
		return Net{}, fmt.Errorf("cannot read %s: %w\n%s", path, err, fixHint)
	}
	defer f.Close()

	raw := ""
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		if strings.TrimSpace(key) == "MPD_VM_ID" {
			raw = strings.TrimSpace(value)
		}
	}
	if err := scanner.Err(); err != nil {
		return Net{}, fmt.Errorf("cannot read %s: %w", path, err)
	}
	if raw == "" {
		return Net{}, fmt.Errorf("MPD_VM_ID is missing or empty in %s\n%s", path, fixHint)
	}
	octet, err := strconv.Atoi(raw)
	if err != nil {
		return Net{}, fmt.Errorf("MPD_VM_ID=%q in %s is not a number\n%s", raw, path, fixHint)
	}
	n, err := New(octet)
	if err != nil {
		return Net{}, fmt.Errorf("%w (from %s)\n%s", err, path, fixHint)
	}
	return n, nil
}

const fixHint = "Re-run the bootstrap step that writes it:\n" +
	"    bash /opt/mpd/bootstrap/30-networking.sh <NNN>   # sandbox: 000; managed: 100..254"

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
