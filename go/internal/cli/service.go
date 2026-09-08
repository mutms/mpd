package cli

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/mutms/mpd/go/internal/cert"
	"github.com/mutms/mpd/go/internal/dnsmasq"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/service"
	"github.com/mutms/mpd/go/internal/srv"
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
	if err := startService(ctx, out, svc, n, p); err != nil {
		return err
	}
	if err := s.UpsertService(state.Service{Name: name, Autostart: true}); err != nil {
		return err
	}
	return PublishDNS(ctx, out, dns, n, false)
}

// startService starts a service and, for a TLS service, issues its
// frontdoor cert and writes the caddy meta. The container work is the
// service framework's; the cert and meta are cli's, like a project's.
func startService(ctx context.Context, out io.Writer, svc service.Service,
	n net.Net, p *podman.Client) error {
	if err := service.Start(ctx, out, svc, n, p); err != nil {
		return err
	}
	if svc.TLS {
		return ensureServiceTLS(ctx, out, svc, n)
	}
	return nil
}

// ensureServiceTLS issues an mpd-signed cert for the service's frontdoor
// name and writes /srv/meta/<name>/{cert.pem,key.pem,cert.sans,urls.json}
// so mpd-caddy serves https://<name>.caddy.<zone> and reverse-proxies to
// the service. urls.json is written last: it makes the vhost appear, and
// the cert files must already exist when the frontdoor reloads.
func ensureServiceTLS(ctx context.Context, out io.Writer, svc service.Service, n net.Net) error {
	host := svc.CaddyDNS(n)
	signature := host

	existing, ok := srv.Read(srv.MetaFile(svc.Name, "cert.sans"))
	needCert := !(ok && strings.TrimSpace(existing) == signature)
	if !needCert {
		if _, hasCert := srv.Read(srv.MetaFile(svc.Name, "cert.pem")); !hasCert {
			needCert = true
		}
	}
	if needCert {
		fmt.Fprintf(out, "\n\033[1m==> Generating TLS certificate for %s\033[0m\n", host)
		certPath := filepath.Join(cert.TempDir, "mpd-svc-"+svc.Name+"-cert.pem")
		keyPath := filepath.Join(cert.TempDir, "mpd-svc-"+svc.Name+"-key.pem")
		defer func() { os.Remove(certPath); os.Remove(keyPath) }()
		if err := cert.Generate(ctx, []string{host}, certPath, keyPath); err != nil {
			return err
		}
		certData, err := os.ReadFile(certPath)
		if err != nil {
			return err
		}
		keyData, err := os.ReadFile(keyPath)
		if err != nil {
			return err
		}
		if err := srv.Write(srv.MetaFile(svc.Name, "cert.pem"), certData, 0o644); err != nil {
			return err
		}
		if err := srv.Write(srv.MetaFile(svc.Name, "key.pem"), keyData, 0o600); err != nil {
			return err
		}
		if err := srv.Write(srv.MetaFile(svc.Name, "cert.sans"), []byte(signature), 0o644); err != nil {
			return err
		}
	}

	backend := map[string]any{
		"type":     "reverse-proxy",
		"upstream": svc.Upstream(n),
	}
	if svc.FrontdoorH2C {
		backend["h2c"] = true
	}
	urls := []map[string]any{{
		"label":   svc.Name,
		"kind":    "reverse-proxy",
		"url":     "https://" + host + "/",
		"backend": backend,
	}}
	return srv.WriteJSON(srv.MetaFile(svc.Name, "urls.json"), urls)
}

// removeServiceMeta drops a TLS service's /srv/meta/<name> directory so
// mpd-caddy stops serving its vhost. A no-op for a plain-HTTP service.
func removeServiceMeta(ctx context.Context, svc service.Service) error {
	if !svc.TLS {
		return nil
	}
	return srv.Remove(ctx, srv.MetaDir(svc.Name))
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
	return PublishDNS(ctx, out, dns, n, false)
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
	if err := startService(ctx, out, svc, n, p); err != nil {
		return err
	}
	// Record presence for DNS + `list`, but never promote an on-demand
	// start to boot-persistent.
	if !serviceRecorded(s, name) {
		if err := s.UpsertService(state.Service{Name: name, Autostart: false}); err != nil {
			return err
		}
	}
	return PublishDNS(ctx, out, dns, n, false)
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
	if err := removeServiceMeta(ctx, svc); err != nil {
		return err
	}
	if err := s.DeleteService(name); err != nil {
		return err
	}
	return PublishDNS(ctx, out, dns, n, false)
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
	if err := removeServiceMeta(ctx, svc); err != nil {
		return err
	}
	if err := s.DeleteService(name); err != nil {
		return err
	}
	return PublishDNS(ctx, out, dns, n, false)
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
		if err := startService(ctx, out, svc, n, p); err != nil {
			fmt.Fprintf(out, "Warning: %v\n", err)
		}
	}
	return nil
}

// ServiceDNSRecords composes the DNS records for every registered
// service. Service addresses are static — the registry fixes each octet
// and the frontdoor is always .2 — so every name is published in advance,
// install state aside: .svc points at the service's own address, and a
// TLS service also gets a .caddy sibling at the frontdoor. A name with
// nothing behind it simply refuses the connection, like a stopped
// service. It lives in cli because the service registry is cli's to
// consult; the fixed infra records are the dnsmasq package's own.
func ServiceDNSRecords(n net.Net) []dnsmasq.Record {
	var records []dnsmasq.Record
	for _, svc := range service.All() {
		// .svc always points straight at the service's own address.
		records = append(records, dnsmasq.Record{IP: svc.IP(n), Names: []string{svc.DNS(n)}})
		// A TLS service also gets a frontdoor name (.caddy) at .2.
		if svc.TLS {
			records = append(records,
				dnsmasq.Record{IP: n.IP(net.HostProjects), Names: []string{svc.CaddyDNS(n)}})
		}
	}
	return records
}

// PublishDNS recomputes every DNS record from state and rewrites the
// /etc/hosts block if it changed. Every mutation path ends with this
// call, so nothing has to remember which record it touched. The VM's
// LAN address is read live in case the network changed.
func PublishDNS(ctx context.Context, out io.Writer, dns dnsmasq.Manager,
	n net.Net, verbose bool) error {
	return dns.Reconcile(ctx, out, ServiceDNSRecords(n), vm.PrimaryIP(), verbose)
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
