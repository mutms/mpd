package runtime

import (
	"context"
	"fmt"
	"io"
	"os"

	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/ui"
)

// RebuildStateCache makes the runtime state cache agree with podman.
// Containers are the ground truth; runs during --vm-setup to reconcile
// a drifted VM.
func RebuildStateCache(ctx context.Context, out io.Writer, p *podman.Client, s state.Store) error {
	containers := p.Ps(ctx, "label=mpd.runtime")

	live := map[string]bool{}
	for _, item := range containers {
		if name := item.Label("mpd.name"); name != "" {
			live[name] = true
		}
	}
	for _, cached := range s.RuntimeNames() {
		if !live[cached] {
			if err := s.DeleteRuntime(cached); err != nil {
				return err
			}
		}
	}

	for _, item := range containers {
		name := item.Label("mpd.name")
		if name == "" {
			continue
		}
		runtimeID := item.Label("mpd.runtime")
		if runtimeID == "" {
			runtimeID = name
		}
		ip := item.Label("mpd.ip")
		if ip == "" {
			ip = p.ContainerIP(ctx, item.Name(), "mpd-internal")
		}
		requested := "stopped"
		if item.State == "running" {
			requested = "running"
		}
		if err := s.SaveRuntime(state.Runtime{
			Name: name, RuntimeID: runtimeID, IP: ip, Requested: requested,
		}); err != nil {
			return err
		}
	}

	if len(containers) == 0 {
		ui.OK(out, "No runtimes found.")
	} else {
		ui.OK(out, "Runtime cache rebuilt (%d runtime(s) found).", len(containers))
	}
	return nil
}

// ReconcileCertificates reissues what a changed CA invalidated: the
// per-project certificates and each running runtime's trust store.
// Call it only when the CA fingerprint changed.
func ReconcileCertificates(ctx context.Context, out io.Writer, p *podman.Client,
	projects []CertTarget, reissue func(string) error) {

	for _, target := range projects {
		fmt.Fprintf(out, "  Renewing cert for %s\n", target.Host)
		_ = os.Remove(srv.MetaFile(target.Name, "cert.pem"))
		_ = os.Remove(srv.MetaFile(target.Name, "key.pem"))
		if err := reissue(target.Name); err != nil {
			ui.Warn(out, "could not reissue cert for %s: %v", target.Name, err)
		}
	}

	for _, item := range p.Ps(ctx, "label=mpd.runtime") {
		container := item.Name()
		if container == "" || !p.Running(ctx, container) {
			continue
		}
		if code, err := p.Copy(ctx, CACertPath,
			container+":/usr/local/share/ca-certificates/mpd-local.crt"); err == nil && code == 0 {
			p.ExecQuietly(ctx, container, "update-ca-certificates")
		}
	}

	ui.OK(out, "Certificate reconciliation completed.")
}

// CertTarget is one project whose certificate must be reissued: Name
// locates its files on the volume, Host is what the transcript shows.
type CertTarget struct{ Name, Host string }

// CACertPath is the CA mpd installs into each runtime's trust store.
const CACertPath = "/var/lib/mpd/conf/caroot/rootCA.pem"
