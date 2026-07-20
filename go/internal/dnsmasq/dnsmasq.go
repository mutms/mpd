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
