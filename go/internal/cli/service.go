package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"path/filepath"

	"github.com/mutms/mpd/go/internal/dnsmasq"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/service"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/vm"
)

// ServiceEnable installs and starts an extra service, records the
// intent, and republishes everything derived from it (DNS record,
// /srv/meta/services.json for configure.sh).
func ServiceEnable(ctx context.Context, out io.Writer, name string,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, n net.Net, vmIP string) error {

	svc, ok := service.Find(name)
	if !ok {
		return unknownService(name)
	}
	if err := service.Enable(ctx, out, svc, n, p); err != nil {
		return err
	}
	if err := s.UpsertService(state.Service{Name: name, Enabled: true}); err != nil {
		return err
	}
	return publishServiceState(ctx, out, p, s, dns, n, vmIP)
}

// ServiceDisable stops a service and turns its auto-start off. The
// container, its volume and its DNS record stay — the octet is static,
// so the record cannot mislead, and keeping it saves resolver churn.
func ServiceDisable(ctx context.Context, out io.Writer, name string,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, n net.Net, vmIP string) error {

	svc, ok := service.Find(name)
	if !ok {
		return unknownService(name)
	}
	if err := service.Disable(ctx, out, svc, p); err != nil {
		return err
	}
	if err := s.UpsertService(state.Service{Name: name, Enabled: false}); err != nil {
		return err
	}
	return publishServiceState(ctx, out, p, s, dns, n, vmIP)
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
	return publishServiceState(ctx, out, p, s, dns, n, vmIP)
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
	return publishServiceState(ctx, out, p, s, dns, n, vmIP)
}

// ReconcileServices converges installed services with their recorded
// intent: enabled ones running (recreated if their revision moved),
// disabled ones left alone. The boot path (`mpd --vm-start`) and setup
// both run this, so a rebooted VM comes back with what was enabled.
func ReconcileServices(ctx context.Context, out io.Writer,
	p *podman.Client, s state.Store, n net.Net) error {

	for _, entry := range s.Services() {
		if !entry.Enabled {
			continue
		}
		svc, ok := service.Find(entry.Name)
		if !ok {
			fmt.Fprintf(out, "Warning: enabled service '%s' is not in the registry — ignoring.\n", entry.Name)
			continue
		}
		if err := service.Enable(ctx, out, svc, n, p); err != nil {
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

// publishServiceState pushes the two derived views of service state:
// the DNS records, and /srv/meta/services.json — the channel a project
// type's configure.sh reads to learn which services are enabled.
func publishServiceState(ctx context.Context, out io.Writer,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, n net.Net, vmIP string) error {

	if err := PublishDNS(ctx, out, dns, n, s, false); err != nil {
		return err
	}
	return WriteServicesMeta(s)
}

// WriteServicesMeta publishes the enabled-service set to
// /srv/meta/services.json, where configure.sh (running inside the
// runtime) reads it with jq. Absent file or absent name both mean "not
// enabled" — correct-by-default for fresh volumes.
func WriteServicesMeta(s state.Store) error {
	var enabled []string
	for _, entry := range s.Services() {
		if entry.Enabled {
			enabled = append(enabled, entry.Name)
		}
	}
	if enabled == nil {
		enabled = []string{}
	}
	data, err := json.MarshalIndent(struct {
		Enabled []string `json:"enabled"`
	}{enabled}, "", "  ")
	if err != nil {
		return err
	}
	return srv.Write(filepath.Join(srv.Meta, "services.json"), append(data, '\n'), 0o644)
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
