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
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
)

// Hosts returns the unique in-zone hostnames from a project's URL list,
// sorted. Single source for cert SANs and DNS records, so the two cannot
// drift; zone filtering stops certs for another VM's names.
func Hosts(urls []state.ProjectURL, n net.Net) []string {
	seen := map[string]bool{}
	for _, u := range urls {
		// A "mail" URL points at the mailpit service, not this
		// project's vhost; its cert and record are the service's.
		if u.Kind == "mail" {
			continue
		}
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
// host, unless the existing one covers exactly that set. The SAN set is
// recorded beside the cert (cert.sans): an existence check alone would
// never widen a stale cert when a project gains hosts.
func EnsureCert(ctx context.Context, out io.Writer, name string, urls []state.ProjectURL,
	n net.Net, p *podman.Client, uid string) error {

	sans := Hosts(urls, n)
	if len(sans) == 0 {
		return nil
	}
	signature := strings.Join(sans, "\n")

	existing, ok := srv.Read(srv.MetaFile(name, "cert.sans"))
	if ok && strings.TrimSpace(existing) == signature {
		// Only trust the signature when the cert it describes is present.
		if _, hasCert := srv.Read(srv.MetaFile(name, "cert.pem")); hasCert {
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

	// srv.Write renames into place; the Caddy frontdoor re-validates on
	// every change and must never see a half-written cert.
	if err := srv.Write(srv.MetaFile(name, "cert.pem"), certData, 0o644); err != nil {
		return err
	}
	if err := srv.Write(srv.MetaFile(name, "key.pem"), keyData, 0o600); err != nil {
		return err
	}
	return srv.Write(srv.MetaFile(name, "cert.sans"), []byte(signature), 0o644)
}

// Exec runs a project script inside its runtime as the dev user.
func Exec(ctx context.Context, p *podman.Client, container, user string, command ...string) (int, error) {
	return p.ExecAsUser(ctx, container, user, command...)
}

// WriteMeta writes /srv/meta/<project>/project.json, the project
// identity readable from inside containers. It must run before a type's
// configure.sh, which reads runtime and type from it; it runs again
// afterwards with the URLs and DB fields configure.sh produced.
func WriteMeta(ctx context.Context, p *podman.Client, uid string, entry state.Project) error {
	meta := map[string]any{
		"name":            entry.Name,
		"type":            entry.Type,
		"runtime":         entry.RuntimeName,
		"databaseId":      entry.DatabaseID,
		"databaseEngine":  entry.DatabaseEngine,
		"databaseVersion": entry.DatabaseVersion,
		"autostart":       entry.Autostart,
		"webRoot":         "/srv/projects/" + entry.Name,
	}
	// Always emit urls, possibly empty, so consumers need not
	// distinguish "absent" from "empty".
	urls := make([]map[string]any, 0, len(entry.URLs))
	for _, u := range entry.URLs {
		urls = append(urls, map[string]any{"label": u.Label, "kind": u.Kind, "url": u.URL})
	}
	meta["urls"] = urls

	return srv.WriteJSON(srv.MetaFile(entry.Name, "project.json"), meta)
}

// ReadURLs returns the URL list configure.sh wrote to
// /srv/meta/<project>/urls.json, and whether the file could be read.
// "No URLs" is a valid state, distinct from "file missing" — the bool
// stops a missing file from overwriting a good cache.
func ReadURLs(name string) ([]state.ProjectURL, bool) {
	var urls []state.ProjectURL
	if !srv.ReadMetaJSON(name, "urls.json", &urls) {
		return nil, false
	}
	return urls, true
}

// CheckConfigured reports what makes a project's configuration unusable
// on this VM — and only what mpd cannot repair by itself. Add future
// invariants here, with the same test: if mpd can repair it, repair it
// instead of reporting it.
func CheckConfigured(name string, urls []state.ProjectURL, n net.Net) error {
	if len(urls) == 0 || len(Hosts(urls, n)) > 0 {
		return nil
	}
	return fmt.Errorf(`Project '%s' is configured for a different VM.

Its URLs name %s, but this VM's zone is %s. That happens when /srv is
restored or copied from another VM, or when MPD_VM_ID changed after the
project was configured.

Regenerate its configuration:

    mpd start %s`, name, foreignHost(urls, n), n.Zone(), name)
}

// foreignHost names one out-of-zone host for the error above.
func foreignHost(urls []state.ProjectURL, n net.Net) string {
	for _, u := range urls {
		parsed, err := url.Parse(u.URL)
		if err != nil || parsed.Hostname() == "" {
			continue
		}
		if !n.IsInZone(parsed.Hostname()) {
			return parsed.Hostname()
		}
	}
	return "no resolvable host"
}

// ReadEffective returns what configure.sh resolved into
// /srv/meta/<project>/effective.json, most importantly dbTag.
func ReadEffective(name string) map[string]any {
	var eff map[string]any
	if !srv.ReadMetaJSON(name, "effective.json", &eff) {
		return nil
	}
	return eff
}
