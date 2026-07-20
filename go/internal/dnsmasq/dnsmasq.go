// Package dnsmasq maintains the DNS records mpd serves for its own
// containers.
//
// Records live as conf.d fragments under <stateDir>/dnsmasq.d/, which is
// bind-mounted read-only into the dnsmasq container at /etc/dnsmasq.d/.
// dnsmasq does NOT reload a conf directory on SIGHUP, so any change here
// requires a container restart — that is why every writer returns
// "changed" and the caller restarts exactly once.
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

// Container is the dnsmasq service container.
const Container = "mpd-service-dnsmasq"

// Manager writes record fragments and restarts dnsmasq when they change.
type Manager struct {
	dir string
	n   net.Net
	p   *podman.Client
}

// New returns a Manager writing into <stateDir>/dnsmasq.d/.
func New(stateDir string, n net.Net, p *podman.Client) Manager {
	return Manager{dir: filepath.Join(stateDir, "dnsmasq.d"), n: n, p: p}
}

// EnsureDatabaseRecords rewrites databases.conf from live containers and
// reports whether the file changed.
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
		lines = append(lines, "address=/"+m.n.DB(r.id)+"/"+r.ip)
	}

	return m.writeIfChanged("databases.conf", strings.Join(lines, "\n")+"\n")
}

// ServiceRecord is one name mpd publishes for an infra service.
type ServiceRecord struct {
	Host string
	IP   string
}

// EnsureServiceRecords rewrites services.conf and reports whether it
// changed.
//
// The apex gets a `host-record` while everything else gets `address=`:
// dnsmasq's `address=/domain/ip` matches the domain AND all its
// subdomains, so using it for the zone apex would make every
// unrecognised name under the zone resolve to the portal — including
// project and runtime names whose own records had not been written yet.
func (m Manager) EnsureServiceRecords(records []ServiceRecord, vmIP string) (bool, error) {
	lines := []string{"# mpd managed service DNS records"}
	for _, r := range records {
		if r.Host == m.n.Zone() {
			lines = append(lines, "host-record="+r.Host+","+r.IP)
		} else {
			lines = append(lines, "address=/"+r.Host+"/"+r.IP)
		}
	}

	// vm.service.<zone> answers with the VM's OWN address rather than a
	// container's, so the host-side orchestrator can confirm it is
	// talking to this VM's dnsmasq and not another's. Skipped on sandbox
	// VMs, which are on DHCP and have no address to publish.
	if vmIP != "" {
		lines = append(lines, "host-record="+m.n.VMServiceRecord()+","+vmIP)
	}

	return m.writeIfChanged("services.conf", strings.Join(lines, "\n")+"\n")
}

// managedFragments are rewritten from scratch on every reconcile, so
// PruneOutOfZone must leave them alone.
var managedFragments = map[string]bool{"services.conf": true, "databases.conf": true}

// PruneOutOfZone deletes fragments that serve names outside this VM's
// zone, reporting whether anything went.
//
// Per-runtime and per-project records are written at create time and
// never revisited. After a VM's ID changes they keep answering for the
// old zone at addresses on the old subnet — names that resolve to
// somewhere nothing listens. The entities they describe have to be
// recreated to get correct records anyway, so a stale fragment has no
// value and its half-working DNS is actively confusing.
func (m Manager) PruneOutOfZone(out io.Writer) bool {
	entries, err := os.ReadDir(m.dir)
	if err != nil {
		return false
	}
	removed := false
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".conf") || managedFragments[name] {
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

// recordHosts extracts the host from each `address=/<host>/<ip>` line.
func recordHosts(body string) []string {
	var hosts []string
	for _, raw := range strings.Split(body, "\n") {
		rest, found := strings.CutPrefix(strings.TrimSpace(raw), "address=/")
		if !found {
			continue
		}
		host, _, _ := strings.Cut(rest, "/")
		if host != "" {
			hosts = append(hosts, host)
		}
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

// Restart restarts dnsmasq so it picks up conf.d changes.
func (m Manager) Restart(ctx context.Context) error {
	_, err := m.p.Restart(ctx, Container)
	return err
}

// writeIfChanged writes content only when it differs, so an unchanged
// reconcile does not trigger a needless dnsmasq restart (which would
// drop in-flight lookups for no reason).
func (m Manager) writeIfChanged(name, content string) (bool, error) {
	path := filepath.Join(m.dir, name)
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

// RemoveRecord deletes a per-project or per-runtime conf fragment.
// Reports whether anything was removed, so the caller restarts dnsmasq
// only when it needs to.
func (m Manager) RemoveRecord(name string) (bool, error) {
	path := filepath.Join(m.dir, name+".conf")
	if _, err := os.Stat(path); err != nil {
		return false, nil
	}
	if err := os.Remove(path); err != nil {
		return false, err
	}
	return true, nil
}

// WriteRecord writes a per-project or per-runtime conf fragment,
// reporting whether it changed.
func (m Manager) WriteRecord(name, body string) (bool, error) {
	return m.writeIfChanged(name+".conf", body)
}
