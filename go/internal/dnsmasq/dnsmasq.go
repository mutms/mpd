// Package dnsmasq publishes the DNS records mpd serves: one managed
// block in the VM's /etc/hosts, read by both glibc and the dnsmasq
// resolver. The whole record set is recomputed from state on every
// change; see docs/networking.md.
package dnsmasq

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/project"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/ui"
	"github.com/mutms/mpd/go/internal/vm"
)

// HostsPath is the file the block lives in; a variable for tests.
var HostsPath = "/etc/hosts"

// Manager computes and publishes the record set.
type Manager struct {
	n net.Net
	p *podman.Client
	s state.Store
	// lanPath is the hosts(5) file of LAN machines; a field for tests.
	lanPath string
}

// New returns a Manager reading projects and services from s and database
// containers from p.
func New(n net.Net, p *podman.Client, s state.Store) Manager {
	return Manager{n: n, p: p, s: s, lanPath: vm.LanHostsPath}
}

// Records composes the full record set, in a fixed order and sorted
// within each group. services come from the caller; vmIP is the VM's
// LAN address, or "" when it has none.
func (m Manager) Records(ctx context.Context, services []Record, vmIP string) []Record {
	records := []Record{
		{IP: m.n.Gateway(), Names: []string{m.n.Zone()}},
	}
	// vm.<zone> answers with the VM's own address so the orchestrator
	// can confirm which VM's resolver replied. Skipped when the VM has
	// no address yet.
	if vmIP != "" {
		records = append(records, Record{IP: vmIP, Names: []string{m.n.VMServiceRecord()}})
	}

	records = append(records, sorted(services)...)
	records = append(records, sorted(m.projectRecords())...)
	records = append(records, sorted(m.databaseRecords(ctx))...)
	records = append(records, sorted(lanRecords(m.lanPath))...)
	return records
}

func sorted(records []Record) []Record {
	sortRecords(records)
	return records
}

// projectRecords lists every in-zone host of every registered project,
// at the project frontdoor address. A configured project stays
// addressable even when stopped.
func (m Manager) projectRecords() []Record {
	projectsIP := m.n.IP(net.HostProjects)
	var records []Record
	for _, pr := range m.s.Projects() {
		for _, host := range project.Hosts(pr.URLs, m.n) {
			records = append(records, Record{IP: projectsIP, Names: []string{host}})
		}
	}
	return records
}

// databaseRecords lists one record per database container, running or
// not. A stopped database keeps its name: "connection refused" says more
// than NXDOMAIN.
func (m Manager) databaseRecords(ctx context.Context) []Record {
	var records []Record
	for _, item := range m.p.Ps(ctx, "label=mpd.type=db") {
		id := item.Label("mpd.name")
		ip := item.Label("mpd.ip")
		if id == "" || !m.n.Contains(ip) {
			continue
		}
		records = append(records, Record{IP: ip, Names: []string{m.n.DB(id)}})
	}
	return records
}

// lanRecords publishes names for LAN machines that are not mpd VMs,
// from the hosts(5) file mpd-virt pushes in. Names outside the mpd tree
// are dropped: this resolver's answers are final, so the file must not
// make it authoritative for foreign names. A missing file means no LAN
// servers.
func lanRecords(path string) []Record {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var records []Record
	for _, raw := range strings.Split(string(body), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		var names []string
		for _, h := range fields[1:] {
			if h == net.RootDomain || strings.HasSuffix(h, "."+net.RootDomain) {
				names = append(names, h)
			}
		}
		if len(names) > 0 {
			records = append(records, Record{IP: fields[0], Names: names})
		}
	}
	return records
}

// Reconcile recomputes the record set, rewrites the block if it differs,
// and reloads the resolver only when it does.
func (m Manager) Reconcile(ctx context.Context, out io.Writer,
	services []Record, vmIP string, verbose bool) error {

	existing, err := os.ReadFile(HostsPath)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("cannot read %s: %w", HostsPath, err)
	}
	body := Splice(string(existing), Render(m.n.Zone(), m.Records(ctx, services, vmIP)))
	if body == string(existing) {
		if verbose {
			ui.OK(out, "DNS records already current in %s.", HostsPath)
		}
		return nil
	}
	if _, err := vm.WriteRootOwnedFile(ctx, HostsPath, body); err != nil {
		return err
	}
	if err := vm.ReloadDnsmasq(ctx); err != nil {
		return err
	}
	if verbose {
		ui.OK(out, "DNS records published in %s.", HostsPath)
	}
	return nil
}
