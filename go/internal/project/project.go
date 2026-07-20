// Package project holds per-project operations that runtime and project
// verbs share: TLS certs, DNS records, and running scripts inside a
// project's runtime.
package project

import (
	"context"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/mutms/mpd/go/internal/cert"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/state"
)

// Hosts returns the unique hostnames from a project's URL list that fall
// inside this VM's zone, sorted.
//
// Single source for both cert SANs and dnsmasq records, so the two can
// never drift. Filtering on the zone rather than the root domain is what
// stops mpd issuing a local cert for a URL naming another VM's project.
func Hosts(urls []state.ProjectURL, n net.Net) []string {
	seen := map[string]bool{}
	for _, u := range urls {
		parsed, err := url.Parse(u.URL)
		if err != nil || parsed.Hostname() == "" {
			continue
		}
		host := parsed.Hostname()
		if n.IsInZone(host) {
			seen[host] = true
		}
	}
	hosts := make([]string, 0, len(seen))
	for h := range seen {
		hosts = append(hosts, h)
	}
	sort.Strings(hosts)
	return hosts
}

// EnsureCert issues a per-project certificate covering every in-zone
// host, unless the existing one already covers exactly that set.
//
// The SAN set is recorded beside the cert (cert.sans) and compared here.
// A bare "does cert.pem exist" check would keep a stale cert forever, so
// enabling behat on an existing project would never widen the cert and
// its behat.<project>.<zone> SNI would fail the handshake. A missing
// signature counts as a mismatch, forcing one regeneration.
func EnsureCert(ctx context.Context, out io.Writer, name string, urls []state.ProjectURL,
	n net.Net, p *podman.Client, uid string) error {

	sans := Hosts(urls, n)
	if len(sans) == 0 {
		return nil
	}
	signature := strings.Join(sans, "\n")

	existing, ok := p.VolumeRead(ctx,
		fmt.Sprintf("/srv/meta/%s/cert.sans", name), uid)
	if ok && strings.TrimSpace(existing) == signature {
		// Only trust the signature when the cert it describes is present.
		if _, hasCert := p.VolumeRead(ctx, fmt.Sprintf("/srv/meta/%s/cert.pem", name), uid); hasCert {
			return nil
		}
	}

	fmt.Fprintf(out, "\n\033[1m==> Generating TLS certificate for %s\033[0m\n", strings.Join(sans, ", "))

	certPath := filepath.Join(cert.TempDir, "mpd-"+name+"-cert.pem")
	keyPath := filepath.Join(cert.TempDir, "mpd-"+name+"-key.pem")
	defer func() {
		os.Remove(certPath)
		os.Remove(keyPath)
	}()
	if err := cert.Generate(ctx, sans, certPath, keyPath); err != nil {
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

	// Temp-then-rename, because the Caddy frontdoor watches this
	// directory and re-validates on every change: a half-written
	// cert.pem fails validation, the reload is skipped, and Caddy keeps
	// serving the previous cert until something restarts it.
	if err := p.VolumeWrite(ctx, uid, fmt.Sprintf(
		"mkdir -p /srv/meta/%s && cat > /srv/meta/%s/cert.pem.tmp && "+
			"mv -f /srv/meta/%s/cert.pem.tmp /srv/meta/%s/cert.pem",
		name, name, name, name), certData); err != nil {
		return err
	}
	if err := p.VolumeWrite(ctx, uid, fmt.Sprintf(
		"cat > /srv/meta/%s/key.pem.tmp && chmod 0600 /srv/meta/%s/key.pem.tmp && "+
			"mv -f /srv/meta/%s/key.pem.tmp /srv/meta/%s/key.pem",
		name, name, name, name), keyData); err != nil {
		return err
	}
	return p.VolumeWrite(ctx, uid,
		fmt.Sprintf("cat > /srv/meta/%s/cert.sans", name), []byte(signature))
}

// DNSRecords returns the dnsmasq fragment for a project: one address
// line per in-zone host, all pointing at its runtime.
func DNSRecords(name string, urls []state.ProjectURL, runtimeIP string, n net.Net) (string, bool) {
	hosts := Hosts(urls, n)
	if len(hosts) == 0 || runtimeIP == "" {
		return "", false
	}
	var b strings.Builder
	for _, h := range hosts {
		fmt.Fprintf(&b, "address=/%s/%s\n", h, runtimeIP)
	}
	return b.String(), true
}

// Exec runs a project script inside its runtime as the dev user.
func Exec(ctx context.Context, p *podman.Client, container, user string, command ...string) (int, error) {
	return p.ExecAsUser(ctx, container, user, command...)
}
