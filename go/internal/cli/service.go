package cli

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/dnsmasq"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/service"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/vm"
)

// ServiceStart installs and runs a service and records it as autostart —
// the sticky, boot-persistent intent that ReconcileServices honours. This is
// the explicit half of the DB-like lifecycle: a service a project merely
// needs is brought up by EnsureService instead, without this flag.
func ServiceStart(ctx context.Context, out io.Writer, name string,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, n net.Net, vmIP string) error {

	svc, ok := service.Find(name)
	if !ok {
		return unknownService(name)
	}
	if err := service.Start(ctx, out, svc, n, p); err != nil {
		return err
	}
	if err := s.UpsertService(state.Service{Name: name, Autostart: true}); err != nil {
		return err
	}
	return PublishDNS(ctx, out, dns, n, s, false)
}

// ServiceStop stops a service and clears its autostart intent. The container,
// its volume and its DNS record stay — the octet is static, so the record
// cannot mislead, and keeping it saves resolver churn. A project that requires
// the service will start it again on its next `mpd start`, exactly as a
// stopped database comes back when a project needs it.
func ServiceStop(ctx context.Context, out io.Writer, name string,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, n net.Net, vmIP string) error {

	svc, ok := service.Find(name)
	if !ok {
		return unknownService(name)
	}
	if err := service.Stop(ctx, out, svc, p); err != nil {
		return err
	}
	if err := s.UpsertService(state.Service{Name: name, Autostart: false}); err != nil {
		return err
	}
	return PublishDNS(ctx, out, dns, n, s, false)
}

// EnsureService starts a service on demand — a project declared it in
// MPD_REQUIRE_SERVICES — the way `mpd start` ensures a project's database.
// It does NOT set the sticky autostart intent: the service runs because a
// project needs it now, and whether it should also come up on its own at boot
// stays the developer's call (`--service-start`). Idempotent; a no-op when the
// service is already running (bar a revision rebuild).
func EnsureService(ctx context.Context, out io.Writer, name string,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, n net.Net, vmIP string) error {

	svc, ok := service.Find(name)
	if !ok {
		return unknownService(name)
	}
	if err := service.Start(ctx, out, svc, n, p); err != nil {
		return err
	}
	// Record its presence for DNS + `list`, but leave any existing autostart
	// intent untouched — an on-demand start must not silently promote a
	// service to boot-persistent.
	if !serviceRecorded(s, name) {
		if err := s.UpsertService(state.Service{Name: name, Autostart: false}); err != nil {
			return err
		}
	}
	return PublishDNS(ctx, out, dns, n, s, false)
}

// serviceRecorded reports whether the service already has a state entry.
func serviceRecorded(s state.Store, name string) bool {
	for _, entry := range s.Services() {
		if entry.Name == name {
			return true
		}
	}
	return false
}

// ServiceUninstall removes the container but keeps the data volume.
func ServiceUninstall(ctx context.Context, out io.Writer, name string,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, n net.Net, vmIP string) error {

	svc, ok := service.Find(name)
	if !ok {
		return unknownService(name)
	}
	if err := service.Uninstall(ctx, out, svc, p); err != nil {
		return err
	}
	if err := s.DeleteService(name); err != nil {
		return err
	}
	return PublishDNS(ctx, out, dns, n, s, false)
}

// ServicePurge removes the container AND its data volume.
func ServicePurge(ctx context.Context, out io.Writer, name string,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, n net.Net, vmIP string) error {

	svc, ok := service.Find(name)
	if !ok {
		return unknownService(name)
	}
	if err := service.Purge(ctx, out, svc, p); err != nil {
		return err
	}
	if err := s.DeleteService(name); err != nil {
		return err
	}
	return PublishDNS(ctx, out, dns, n, s, false)
}

// ReconcileServices converges installed services with their recorded
// intent: autostart ones running (recreated if their revision moved), the
// rest left alone. The boot path (`mpd --vm-start`) and setup both run this,
// so a rebooted VM comes back with what the developer marked autostart. A
// service that only some project needs is not started here — it comes up when
// that project's `mpd start` ensures it, like the project's database.
func ReconcileServices(ctx context.Context, out io.Writer,
	p *podman.Client, s state.Store, n net.Net) error {

	for _, entry := range s.Services() {
		if !entry.Autostart {
			continue
		}
		svc, ok := service.Find(entry.Name)
		if !ok {
			fmt.Fprintf(out, "Warning: autostart service '%s' is not in the registry — ignoring.\n", entry.Name)
			continue
		}
		if err := service.Start(ctx, out, svc, n, p); err != nil {
			fmt.Fprintf(out, "Warning: %v\n", err)
		}
	}
	return nil
}

// ServiceDNSRecords composes one DNS record per INSTALLED extra service,
// pointing at its own address. This lives in cli rather than in the
// dnsmasq package because the service registry is cli's to consult; the
// fixed infra records (apex, runtime, vm) are the dnsmasq package's own.
func ServiceDNSRecords(n net.Net, s state.Store) []dnsmasq.Record {
	var records []dnsmasq.Record
	for _, entry := range s.Services() {
		if svc, ok := service.Find(entry.Name); ok {
			records = append(records, dnsmasq.Record{IP: svc.IP(n), Names: []string{svc.DNS(n)}})
		}
	}
	return records
}

// PublishDNS recomputes every DNS record from state and rewrites the
// block in /etc/hosts if it changed. The one call every mutation path
// ends with — project, database, service, runtime, boot — so nothing has
// to remember which record it touched. The VM's LAN address is read live
// here: a VM that rebooted on a different network must not keep answering
// vm.<zone> with the old one.
func PublishDNS(ctx context.Context, out io.Writer, dns dnsmasq.Manager,
	n net.Net, s state.Store, verbose bool) error {
	return dns.Reconcile(ctx, out, ServiceDNSRecords(n, s), vm.PrimaryIP(), verbose)
}

func unknownService(name string) error {
	return fmt.Errorf("Unknown service '%s'. Available: %s.",
		name, joinNames(service.Names()))
}

func joinNames(names []string) string {
	out := ""
	for i, n := range names {
		if i > 0 {
			out += ", "
		}
		out += n
	}
	return out
}
