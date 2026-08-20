// Package dnsmasq maintains the DNS records mpd serves for its own
// containers.
//
// Records are hosts files under <stateDir>/dns/, which the resolver reads
// via dnsmasq's `hostsdir=`. That directive is the reason this package has
// no Restart: dnsmasq watches the directory and re-reads it on every add,
// change and remove, flushing the cache for just the affected names.
// Publishing a record is a file write and nothing else.
//
// It was not always so. These records used to be `address=/host/ip`
// fragments in a `conf-dir=`, which dnsmasq reads only at startup — not
// even SIGHUP re-reads a config file. Every `mpd init` and `mpd delete`
// therefore restarted the resolver, and although the restart itself took
// 0.2s, a client whose query was in flight paid glibc's full
// `timeout:5 attempts:2` — ten seconds of "Temporary failure in name
// resolution" for every other project on the VM.
//
// The format change is not merely a serialisation detail. `address=/x/ip`
// answers for x AND every name beneath it, so it was a wildcard that
// happened to be used for exact names; a hosts entry answers only the
// name written. Since mpd enumerates every name it publishes, exact match
// is what was meant all along, and unknown names under the zone now
// NXDOMAIN by construction rather than by careful use of a wildcard.
package dnsmasq

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
)

// recordSuffix marks the files in the hosts directory mpd owns. dnsmasq
// reads every file in a hostsdir regardless of name, so the suffix is for
// humans and for PruneOutOfZone, not for dnsmasq.
const recordSuffix = ".hosts"

// Manager writes record files into the resolver's hosts directory.
//
// No restart method, and none is wanted: see the package comment.
type Manager struct {
	dir string
	n   net.Net
	p   *podman.Client
}

// New returns a Manager writing into <stateDir>/dns/.
func New(stateDir string, n net.Net, p *podman.Client) Manager {
	return Manager{dir: filepath.Join(stateDir, "dns"), n: n, p: p}
}

// hostsLine renders one record. Hosts syntax: address first, then the
// names it answers for.
func hostsLine(host, ip string) string { return ip + " " + host }

// EnsureDatabaseRecords rewrites the database records from live
// containers and reports whether the file changed.
//
// Addresses come from podman rather than from databases.json: a stopped
// container has no address, so its record must disappear — pointing a
// name at a dead address is worse than not resolving it.
func (m Manager) EnsureDatabaseRecords(ctx context.Context) (bool, error) {
	lines := []string{"# mpd managed database DNS records"}

	type record struct{ id, ip string }
	var records []record
	for _, item := range m.p.Ps(ctx, "label=mpd.type=db") {
		id := item.Label("mpd.name")
		if id == "" {
			continue
		}
		container := item.Name()
		if container == "" {
			container = "mpd-db-" + id
		}
		ip := m.p.ContainerIP(ctx, container, "mpd-internal")
		if ip == "" {
			continue
		}
		records = append(records, record{id: id, ip: ip})
	}
	sort.Slice(records, func(i, j int) bool { return records[i].id < records[j].id })
	for _, r := range records {
		lines = append(lines, hostsLine(m.n.DB(r.id), r.ip))
	}

	return m.writeIfChanged("databases", strings.Join(lines, "\n")+"\n")
}

// ServiceRecord is one name mpd publishes for an infra service.
type ServiceRecord struct {
	Host string
	IP   string
}

// EnsureServiceRecords rewrites the service records and reports whether
// they changed.
func (m Manager) EnsureServiceRecords(records []ServiceRecord, vmIP string) (bool, error) {
	lines := []string{"# mpd managed service DNS records"}
	for _, r := range records {
		lines = append(lines, hostsLine(r.Host, r.IP))
	}

	// vm.<zone> answers with the VM's OWN address rather than a
	// container's, so the host-side orchestrator can confirm it is
	// talking to this VM's resolver and not another's. Skipped on sandbox
	// VMs, which are on DHCP and have no address to publish.
	if vmIP != "" {
		lines = append(lines, hostsLine(m.n.VMServiceRecord(), vmIP))
	}

	return m.writeIfChanged("services", strings.Join(lines, "\n")+"\n")
}

// EnsureLANRecords publishes names for machines on the local network that
// are not mpd VMs — `forge.mpd.test`, `proxmox.mpd.test` — and reports
// whether they changed.
//
// The source is a hosts(5) file the workstation's orchestrator pushes in
// (`mpd-virt server sync`). It is copied through rather than derived,
// because nothing in the VM knows what is on the LAN; the VM's job is to
// answer for it so that containers, which resolve through this resolver
// and have no /etc/hosts of their own, can reach those hosts by name and
// verify their TLS against a CA they already trust.
//
// Names outside the mpd tree are dropped. A hosts file that could publish
// anything would make this resolver authoritative for names it has no
// business answering — and `local=/test/` means an answer here is final.
func (m Manager) EnsureLANRecords(path string) (bool, error) {
	lines := []string{"# mpd managed LAN service DNS records"}

	// A missing file is not an error: it means no LAN servers are
	// registered on the workstation. The record file is still written, so
	// removing the last server retracts the names it used to publish.
	if body, err := os.ReadFile(path); err == nil {
		for _, raw := range strings.Split(string(body), "\n") {
			line := strings.TrimSpace(raw)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			fields := strings.Fields(line)
			if len(fields) < 2 {
				continue
			}
			var hosts []string
			for _, h := range fields[1:] {
				if h == net.RootDomain || strings.HasSuffix(h, "."+net.RootDomain) {
					hosts = append(hosts, h)
				}
			}
			if len(hosts) == 0 {
				continue
			}
			lines = append(lines, hostsLine(strings.Join(hosts, " "), fields[0]))
		}
	}

	return m.writeIfChanged("lan", strings.Join(lines, "\n")+"\n")
}

// managedRecords are rewritten from scratch on every reconcile, so
// PruneOutOfZone must leave them alone.
//
// "lan" belongs here for a reason that is easy to miss: every LAN name is
// by definition outside this VM's zone, which is exactly the condition
// PruneOutOfZone deletes a record file for. Without this entry the LAN
// records would be published, work, and then vanish on the next
// reconcile — most visibly at the following `mpd --vm-start`.
var managedRecords = map[string]bool{"services": true, "databases": true, "lan": true}

// PruneOutOfZone deletes record files serving names outside this VM's
// zone, reporting whether anything went.
//
// Per-runtime and per-project records are written at create time and
// never revisited. After a VM's ID changes they keep answering for the
// old zone at addresses on the old subnet — names that resolve to
// somewhere nothing listens. The entities they describe have to be
// recreated to get correct records anyway, so a stale record has no
// value and its half-working DNS is actively confusing.
func (m Manager) PruneOutOfZone(out io.Writer) bool {
	entries, err := os.ReadDir(m.dir)
	if err != nil {
		return false
	}
	removed := false
	for _, e := range entries {
		name := e.Name()
		base, ok := strings.CutSuffix(name, recordSuffix)
		if !ok || managedRecords[base] {
			continue
		}
		path := filepath.Join(m.dir, name)
		body, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		hosts := recordHosts(string(body))
		if len(hosts) == 0 || !anyOutOfZone(m.n, hosts) {
			continue
		}
		if os.Remove(path) != nil {
			continue
		}
		removed = true
		fmt.Fprintf(out, "  Removed stale DNS record file %s (not in %s)\n", name, m.n.Zone())
	}
	return removed
}

// recordHosts extracts every name a hosts file answers for. A line is an
// address followed by one or more names; comments and blanks carry none.
func recordHosts(body string) []string {
	var hosts []string
	for _, raw := range strings.Split(body, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		hosts = append(hosts, fields[1:]...)
	}
	return hosts
}

func anyOutOfZone(n net.Net, hosts []string) bool {
	for _, h := range hosts {
		if !n.IsInZone(h) {
			return true
		}
	}
	return false
}

// writeIfChanged writes content only when it differs. Unchanged content
// is not rewritten, so dnsmasq's directory watch does not fire and the
// cache for those names is not flushed for nothing.
func (m Manager) writeIfChanged(name, content string) (bool, error) {
	path := filepath.Join(m.dir, name+recordSuffix)
	if existing, err := os.ReadFile(path); err == nil && string(existing) == content {
		return false, nil
	}
	if err := os.MkdirAll(m.dir, 0o755); err != nil {
		return false, err
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		return false, err
	}
	return true, nil
}

// RemoveRecord deletes a per-project or per-runtime record file.
// Reports whether anything was removed.
func (m Manager) RemoveRecord(name string) (bool, error) {
	path := filepath.Join(m.dir, name+recordSuffix)
	if _, err := os.Stat(path); err != nil {
		return false, nil
	}
	if err := os.Remove(path); err != nil {
		return false, err
	}
	return true, nil
}

// WriteRecord writes a per-project or per-runtime record file, reporting
// whether it changed.
func (m Manager) WriteRecord(name, body string) (bool, error) {
	return m.writeIfChanged(name, body)
}

// Line renders one record for a caller assembling a record body itself —
// project records, which pair many names with one runtime address.
func Line(host, ip string) string { return hostsLine(host, ip) }
