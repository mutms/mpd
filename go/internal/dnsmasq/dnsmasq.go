// Package dnsmasq publishes the DNS records mpd serves for its names: one
// managed block in the VM's /etc/hosts.
//
// /etc/hosts is the single record store on purpose. glibc on the VM reads
// it first (`files` leads nsswitch's hosts line on every Debian install),
// so the VM resolves its own zone without any resolver in the path; the
// resolver on the bridge (dnsmasq, see vm.DnsmasqConfBody) reads the same
// file and hands the same answers to every container and to the laptop.
// One file, two readers, no routing between resolvers — which is what
// removed the "name NXDOMAINs for minutes after boot" failure that a stack
// of resolvers with negative caches used to produce.
//
// The whole record set is recomputed from state on every change and the
// block rewritten only when it differs, so there is nothing to add or
// remove per entity and nothing that can go stale: projects come from
// projects.json, databases from their containers, services from
// services.json, LAN names from the file mpd-virt pushes in.
//
// A changed block is followed by a SIGHUP to dnsmasq (systemctl reload),
// which re-reads /etc/hosts and clears its cache without dropping in-flight
// queries. That distinction matters: a restart would cost any client mid-
// query glibc's full timeout.
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

// HostsPath is the file the block lives in. A variable so tests can point
// the manager at a scratch file.
var HostsPath = "/etc/hosts"

// Manager computes and publishes the record set.
type Manager struct {
	n net.Net
	p *podman.Client
	s state.Store
	// lanPath is the hosts(5) file of LAN machines (vm.LanHostsPath); a
	// field so tests can point it at a fixture.
	lanPath string
}

// New returns a Manager reading projects and services from s and database
// containers from p.
func New(n net.Net, p *podman.Client, s state.Store) Manager {
	return Manager{n: n, p: p, s: s, lanPath: vm.LanHostsPath}
}

// Records composes the full record set, in a fixed order and sorted within
// each group. services are the infra and extra-service records the caller
// composes (it owns the service registry); vmIP is the VM's LAN address,
// read live off the interface, or "" when it has none.
func (m Manager) Records(ctx context.Context, services []Record, vmIP string) []Record {
	// The runtime's line carries the bare `runtime` alias, so `ssh runtime`
	// works on the VM — and through a ProxyJump from the laptop, where the
	// VM's own libc resolves the target — without a search domain.
	records := []Record{
		{IP: m.n.Gateway(), Names: []string{m.n.Zone()}},
		{IP: m.n.IP(net.HostRuntime), Names: []string{m.n.RuntimeFQDN(), "runtime"}},
	}
	// vm.<zone> answers with the VM's OWN address rather than a
	// container's, so the host-side orchestrator can confirm it is talking
	// to this VM's resolver and not another's. Skipped when the VM has no
	// address yet (a DHCP sandbox mid-boot).
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

// projectRecords: every in-zone host of every registered project, at the
// runtime's fixed address. A configured project is an addressable one
// whether or not it is started — a dead page is the honest answer, and the
// only one that works for types whose server the developer starts by hand.
func (m Manager) projectRecords() []Record {
	runtimeIP := m.n.IP(net.HostRuntime)
	var records []Record
	for _, pr := range m.s.Projects() {
		for _, host := range project.Hosts(pr.URLs, m.n) {
			records = append(records, Record{IP: runtimeIP, Names: []string{host}})
		}
	}
	return records
}

// databaseRecords: one per database container, running or not, at the
// address pinned in its label when it was created. A stopped database
// keeps its name on purpose: the address is still its own, and
// "connection refused" says more than NXDOMAIN would.
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

// lanRecords publishes names for machines on the local network that are
// not mpd VMs — `forge.mpd.test`, `proxmox.mpd.test` — from the hosts(5)
// file the workstation's orchestrator pushes in (`mpd-virt server sync`).
// Nothing in the VM knows what is on the LAN; the VM's job is to answer
// for it so containers, which resolve through this VM, can reach those
// hosts by name and verify their TLS against a CA they already trust.
//
// Names outside the mpd tree are dropped: `local=/test/` makes an answer
// from this resolver final, so a file that could publish anything would
// make it authoritative for names it has no business answering.
//
// A missing file is not an error — no LAN servers are registered.
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

// Reconcile recomputes the record set, rewrites the block in /etc/hosts if
// it differs, and reloads the resolver when it does. Unchanged content is
// not written and nothing is signalled.
//
// verbose is off on the daily path, where "nothing moved" is the normal
// answer and saying so on every `--vm-start` is noise.
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
