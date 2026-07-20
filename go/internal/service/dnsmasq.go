package service

import (
	"context"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/mutms/mpd/go/internal/dnsmasq"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/ui"
	"github.com/mutms/mpd/go/internal/vm"
)

// DnsmasqImage is pinned rather than tracking latest: this container is
// the VM's only resolver, and an upstream change that broke it would
// take every name in the zone down with it.
const DnsmasqImage = "docker.io/4km3/dnsmasq:2.90-r3"

// hostResolvConf is the file dnsmasq reads upstream nameservers from.
//
// systemd-resolved is active on every supported profile, so
// /etc/resolv.conf is a stub pointing at 127.0.0.53 and the real
// per-link upstreams live here. Bind-mounting this — rather than
// hardcoding a public resolver or asking for one in an env var — is what
// makes mpd work unchanged on a corporate VPN, a home LAN, or a laptop
// tethered to a phone.
const hostResolvConf = "/run/systemd/resolve/resolv.conf"

// SetupDnsmasq creates and configures the dnsmasq container, and brings
// its records up to date. Idempotent.
func SetupDnsmasq(ctx context.Context, out io.Writer, p *podman.Client, n net.Net,
	m dnsmasq.Manager, caFingerprint, vmIP string) error {

	p.RemoveIfOutdated(ctx, dnsmasq.Container, map[string]string{
		RevisionLabel:      dnsmasqRevision,
		CAFingerprintLabel: caFingerprint,
	})

	ui.Step(out, "Service: dnsmasq")

	conf := vm.AssetsDir + "/services/dnsmasq/dnsmasq.conf"
	if _, err := os.Stat(conf); err != nil {
		return fmt.Errorf("dnsmasq.conf not found at %s", conf)
	}
	if err := os.MkdirAll(vm.DnsmasqDir, 0o755); err != nil {
		return err
	}

	changed, err := reconcileRecords(ctx, out, m, n, vmIP)
	if err != nil {
		return err
	}

	switch {
	case !p.Exists(ctx, dnsmasq.Container):
		fmt.Fprintln(out, "Creating dnsmasq container")
		args := append([]string{}, podman.OptMountRO...)
		args = append(args,
			"-d", "--name", dnsmasq.Container,
			"--network", "mpd-internal:ip="+n.IP(net.HostDnsmasq),
			"--restart", "always",
			"-v", conf+":/etc/dnsmasq.conf:ro",
			// A DIRECTORY mount, so fragment adds and removes are
			// visible inside the container immediately.
			"-v", vm.DnsmasqDir+":/etc/dnsmasq.d:ro",
			"-v", hostResolvConf+":/etc/dnsmasq-host-resolv.conf:ro",
			"--label", "com.docker.compose.project=mpd-service",
			"--label", RevisionLabel+"="+dnsmasqRevision,
			"--label", CAFingerprintLabel+"="+caFingerprint,
			DnsmasqImage,
		)
		if code, err := p.Run(ctx, args); err != nil || code != 0 {
			return fmt.Errorf("Failed to start %s.", dnsmasq.Container)
		}
		ui.OK(out, "dnsmasq running.")
	case !p.Running(ctx, dnsmasq.Container):
		if _, err := p.Start(ctx, dnsmasq.Container); err != nil {
			return err
		}
		WaitForDnsmasq(ctx, out, p, n)
		ui.OK(out, "dnsmasq running.")
	case changed.any():
		if err := m.Restart(ctx); err != nil {
			return err
		}
		WaitForDnsmasq(ctx, out, p, n)
		ui.OK(out, "%s", changed.message())
	default:
		ui.OK(out, "dnsmasq already running.")
	}
	return nil
}

// EnsureDnsmasqReady is the lighter path used when starting rather than
// setting up: the container must already exist, records are refreshed,
// and dnsmasq is restarted only if something moved.
func EnsureDnsmasqReady(ctx context.Context, out io.Writer, p *podman.Client, n net.Net,
	m dnsmasq.Manager, vmIP string, verbose bool) error {

	if !p.Exists(ctx, dnsmasq.Container) {
		return fmt.Errorf("%s not found. Run: mpd --setup", dnsmasq.Container)
	}
	if err := os.MkdirAll(vm.DnsmasqDir, 0o755); err != nil {
		return err
	}

	changed, err := reconcileRecords(ctx, out, m, n, vmIP)
	if err != nil {
		return err
	}

	switch {
	case !p.Running(ctx, dnsmasq.Container):
		if code, err := p.Start(ctx, dnsmasq.Container); err != nil || code != 0 {
			return fmt.Errorf("Failed to start %s. Run: mpd --setup", dnsmasq.Container)
		}
		WaitForDnsmasq(ctx, out, p, n)
		if verbose {
			ui.OK(out, "dnsmasq running.")
		}
	case changed.any():
		if err := m.Restart(ctx); err != nil {
			return err
		}
		WaitForDnsmasq(ctx, out, p, n)
		if verbose {
			ui.OK(out, "%s", changed.message())
		}
	default:
		if verbose {
			ui.OK(out, "dnsmasq already running.")
		}
	}
	return nil
}

// recordChanges tracks which fragment groups moved, because the message
// the user sees names them.
type recordChanges struct{ stale, services, databases bool }

func (c recordChanges) any() bool { return c.stale || c.services || c.databases }

func (c recordChanges) message() string {
	if c.databases {
		return "dnsmasq reloaded service and database DNS records."
	}
	return "dnsmasq reloaded service DNS records."
}

func reconcileRecords(ctx context.Context, out io.Writer, m dnsmasq.Manager,
	n net.Net, vmIP string) (recordChanges, error) {

	var c recordChanges
	c.stale = m.PruneOutOfZone(out)

	records := make([]dnsmasq.ServiceRecord, 0, len(DNSRecords(n)))
	for _, r := range DNSRecords(n) {
		records = append(records, dnsmasq.ServiceRecord{Host: r.Host, IP: r.IP})
	}
	var err error
	if c.services, err = m.EnsureServiceRecords(records, vmIP); err != nil {
		return c, err
	}
	if c.databases, err = m.EnsureDatabaseRecords(ctx); err != nil {
		return c, err
	}
	return c, nil
}

// WaitForDnsmasq blocks until dnsmasq answers, so callers that go
// straight on to create a project or runtime do not race a half-started
// resolver.
//
// Probes from inside the container against a name mpd itself publishes.
// Internal-only on purpose: external resolution depends on the host's
// upstream chain, which is not dnsmasq's readiness to prove, and a
// caller that needs a specific external host should probe that host.
//
// Non-fatal — warns and returns, because a slow resolver is not a reason
// to fail the command that was actually asked for.
func WaitForDnsmasq(ctx context.Context, out io.Writer, p *podman.Client, n net.Net) {
	const (
		interval = 250 * time.Millisecond
		attempts = 20 // 5 seconds
	)
	for i := 0; i < attempts; i++ {
		if p.ExecQuietly(ctx, dnsmasq.Container, "nslookup", n.Zone(), "127.0.0.1") == 0 {
			return
		}
		time.Sleep(interval)
	}
	fmt.Fprintln(out, "Warning: dnsmasq did not become ready within 5s — DNS lookups may fail.")
}
