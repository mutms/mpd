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
	"github.com/mutms/mpd/go/internal/dnsmasq"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/srv"
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
		// A "mail" URL points at the mailpit SERVICE (its own address,
		// its own DNS record), not at this project's vhost — issuing a
		// project cert or DNS record for it would fight the service's.
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

	// srv.Write renames into place, which the Caddy frontdoor depends on:
	// it re-validates on every change, and a half-written cert.pem fails
	// validation, skipping the reload.
	if err := srv.Write(srv.MetaFile(name, "cert.pem"), certData, 0o644); err != nil {
		return err
	}
	if err := srv.Write(srv.MetaFile(name, "key.pem"), keyData, 0o600); err != nil {
		return err
	}
	return srv.Write(srv.MetaFile(name, "cert.sans"), []byte(signature), 0o644)
}

// DNSRecords returns the resolver's record file for a project: one hosts
// line per in-zone host, all pointing at its runtime.
func DNSRecords(name string, urls []state.ProjectURL, runtimeIP string, n net.Net) (string, bool) {
	hosts := Hosts(urls, n)
	if len(hosts) == 0 || runtimeIP == "" {
		return "", false
	}
	var b strings.Builder
	for _, h := range hosts {
		fmt.Fprintln(&b, dnsmasq.Line(h, runtimeIP))
	}
	return b.String(), true
}

// Exec runs a project script inside its runtime as the dev user.
func Exec(ctx context.Context, p *podman.Client, container, user string, command ...string) (int, error) {
	return p.ExecAsUser(ctx, container, user, command...)
}

// WriteMeta writes /srv/meta/<project>/project.json — the ground-truth
// project identity readable from inside containers.
//
// Written BEFORE a project type's configure.sh runs, because
// source-mpd-env.sh reads runtime and type from it to locate the
// matching mpd-defaults.env layers. Written again afterwards, once
// configure.sh has produced URLs and DB fields.
func WriteMeta(ctx context.Context, p *podman.Client, uid string, entry state.Project) error {
	meta := map[string]any{
		"name":            entry.Name,
		"type":            entry.Type,
		"runtime":         entry.RuntimeName,
		"databaseId":      entry.DatabaseID,
		"databaseEngine":  entry.DatabaseEngine,
		"databaseVersion": entry.DatabaseVersion,
		"requested":       entry.Requested,
		"webRoot":         "/srv/projects/" + entry.Name,
	}
	// Always emit urls, possibly empty, so consumers need not distinguish
	// "absent" from "present but empty" — they are the same thing.
	urls := make([]map[string]any, 0, len(entry.URLs))
	for _, u := range entry.URLs {
		urls = append(urls, map[string]any{"label": u.Label, "kind": u.Kind, "url": u.URL})
	}
	meta["urls"] = urls

	return srv.WriteJSON(srv.MetaFile(entry.Name, "project.json"), meta)
}

// ReadURLs returns the URL list a project type's configure.sh wrote to
// /srv/meta/<project>/urls.json, and whether the file could be read.
//
// The bool matters to callers refreshing a cached copy: "no URLs" is a
// valid project state (a bare or cftunnel project publishes none), and it
// is not the same answer as "the file is missing", which would otherwise
// overwrite a good cache with nothing.
func ReadURLs(name string) ([]state.ProjectURL, bool) {
	var urls []state.ProjectURL
	if !srv.ReadMetaJSON(name, "urls.json", &urls) {
		return nil, false
	}
	return urls, true
}

// CheckConfigured reports what makes a project's configuration unusable on
// THIS VM — and only what mpd cannot repair by itself.
//
// The distinction is the whole point. A stale copy of urls.json in
// projects.json is not a problem to report, because whoever noticed it can
// simply re-read the file; telling a developer to run `mpd start` for
// something mpd could fix itself is noise dressed as diagnostics. What
// lands here is the opposite case: configuration that was written for a
// different VM and can only be regenerated by re-running the project
// type's configure.sh, which resolves database tags and may create
// containers — too much for a start verb to do behind someone's back.
//
// Add future invariants here rather than in the verbs, and apply the same
// test to each: if mpd can repair it, repair it instead.
func CheckConfigured(name string, urls []state.ProjectURL, n net.Net) error {
	if len(urls) == 0 || len(Hosts(urls, n)) > 0 {
		return nil
	}
	// Every URL names somewhere else: /srv came from another VM, or this
	// VM's MPD_VM_ID changed under a project configured before it did.
	return fmt.Errorf(`Project '%s' is configured for a different VM.

Its URLs name %s, but this VM's zone is %s. That happens when /srv is
restored or copied from another VM, or when MPD_VM_ID changed after the
project was configured.

Regenerate its configuration:

    mpd start %s`, name, foreignHost(urls, n), n.Zone(), name)
}

// foreignHost names one out-of-zone host, for the error above. The first
// is enough — they all moved together.
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

// ReadEffective returns what a project type's configure.sh resolved into
// /srv/meta/<project>/effective.json — most importantly dbTag, which is
// how the layered mpd.env cascade reaches mpd.
func ReadEffective(name string) map[string]any {
	var eff map[string]any
	if !srv.ReadMetaJSON(name, "effective.json", &eff) {
		return nil
	}
	return eff
}
