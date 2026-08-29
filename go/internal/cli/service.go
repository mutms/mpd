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

// ServiceStart installs and runs a service and records it as autostart,
// the boot-persistent intent ReconcileServices honours. A service a
// project merely needs goes through EnsureService, without this flag.
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

// ServiceStop stops a service and clears its autostart intent. The
// container, volume and DNS record stay — the address is static, so the
// record cannot mislead. A project that requires the service starts it
// again on its next `mpd start`.
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

// EnsureService starts a service a project declared in
// MPD_REQUIRE_SERVICES. It does not set autostart — boot persistence
// stays the developer's call via --service-start. Idempotent.
func EnsureService(ctx context.Context, out io.Writer, name string,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, n net.Net, vmIP string) error {

	svc, ok := service.Find(name)
	if !ok {
		return unknownService(name)
	}
	if err := service.Start(ctx, out, svc, n, p); err != nil {
		return err
	}
	// Record presence for DNS + `list`, but never promote an on-demand
	// start to boot-persistent.
	if !serviceRecorded(s, name) {
		if err := s.UpsertService(state.Service{Name: name, Autostart: false}); err != nil {
			return err
		}
	}
	return PublishDNS(ctx, out, dns, n, s, false)
}

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

// ReconcileServices starts every service marked autostart (recreating
// on revision drift) and leaves the rest alone. Boot and setup both run
// this. A service only a project needs comes up via that project's
// `mpd start`.
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

// ServiceDNSRecords composes one DNS record per installed extra service.
// It lives in cli because the service registry is cli's to consult; the
// fixed infra records are the dnsmasq package's own.
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
// /etc/hosts block if it changed. Every mutation path ends with this
// call, so nothing has to remember which record it touched. The VM's
// LAN address is read live in case the network changed.
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
