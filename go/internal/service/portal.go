package service

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/mutms/mpd/go/internal/cert"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/ui"
	"github.com/mutms/mpd/go/internal/vm"
)

// PortalContainer serves the zone apex and reverse-proxies the services
// that have no TLS of their own.
const PortalContainer = "mpd-service-portal"

// portalSetupCmd installs apache and PHP into a stock Debian container
// on first boot, then runs apache in the foreground.
//
// Inline rather than a built image: the portal is a handful of static
// files plus one PHP script, and building an image for it would add a
// build step to every `--vm-setup` for no gain. `--restart always` plus a
// container that is only rebuilt on a revision bump means this runs
// once per rebuild, not once per boot.
const portalSetupCmd = "apt-get update -qq && apt-get install -y --no-install-recommends " +
	"apache2 php libapache2-mod-php && " +
	"for d in /etc/php/*/apache2/conf.d; do " +
	"[ -d \"$d\" ] || continue; " +
	"cp /tmp/mpd-portal.ini \"$d/99-mpd-portal.ini\"; " +
	"done && " +
	"a2enmod ssl proxy proxy_http && a2dissite 000-default && a2ensite mpd-portal && " +
	"apachectl -D FOREGROUND"

// SetupPortal creates and configures the portal container. Idempotent.
//
// SECURITY: the portal is strictly read-only. Every mount it gets is
// :ro, it never executes a command, and it accepts no user input — it
// renders what mpd has already written to the state directory and the
// data volume. Keep it that way: it is the one mpd component reachable
// from a browser.
func SetupPortal(ctx context.Context, out io.Writer, p *podman.Client, n net.Net,
	caFingerprint, devUser string) error {

	ui.Step(out, "Service: portal at https://%s", n.Zone())

	p.RemoveIfOutdated(ctx, PortalContainer, map[string]string{
		RevisionLabel:      portalRevision,
		CAFingerprintLabel: caFingerprint,
	})

	assetDir := vm.AssetsDir + "/services/portal"
	var (
		portalWWW     = assetDir + "/www"
		apacheConf    = assetDir + "/apache.conf"
		portalPHPIni  = assetDir + "/php.ini"
		vhostTemplate = assetDir + "/templates/service-vhost.conf.tpl"
	)
	for _, required := range []struct{ path, label string }{
		{portalWWW + "/index.php", "portal/www/index.php"},
		{apacheConf, "portal/apache.conf"},
		{vhostTemplate, "portal/templates/service-vhost.conf.tpl"},
		{portalPHPIni, "portal/php.ini"},
	} {
		if _, err := os.Stat(required.path); err != nil {
			return fmt.Errorf("%s not found at %s", required.label, required.path)
		}
	}

	stateDir := vm.StateDir + "/portal"
	var (
		vhostsDir  = stateDir + "/vhosts"
		certsDir   = stateDir + "/certs"
		certOpsDir = stateDir + "/certops"
	)
	for _, dir := range []string{vhostsDir, certsDir, certOpsDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}

	// The portal already mounts the state dir read-only, so these two
	// files reach it without another bind mount. PHP reads them per
	// request, so an edit shows up on the next refresh.
	host, _ := os.Hostname()
	_ = os.WriteFile(filepath.Join(stateDir, "display-name.txt"), []byte(host), 0o644)
	// The dev user drives the IDE deep links (vscode://,
	// jetbrains-gateway://) in the per-project popover: a runtime's user
	// matches the VM's, and the Remote-SSH target has to name it.
	_ = os.WriteFile(filepath.Join(stateDir, "dev-user.txt"), []byte(devUser), 0o644)

	// ServerName and the :80 redirect both name the zone apex, which is
	// per-VM — so the asset is a template and the rendered copy is what
	// gets mounted.
	renderedApache := filepath.Join(stateDir, "apache.conf")
	template, err := os.ReadFile(apacheConf)
	if err != nil {
		return fmt.Errorf("portal/apache.conf unreadable at %s", apacheConf)
	}
	if err := os.WriteFile(renderedApache,
		[]byte(strings.ReplaceAll(string(template), "%%ZONE%%", n.Zone())), 0o644); err != nil {
		return err
	}

	proxyChanged, err := ensureProxyArtifacts(ctx, n, vhostTemplate, stateDir,
		vhostsDir, certsDir, caFingerprint)
	if err != nil {
		return err
	}

	switch {
	case !p.Exists(ctx, PortalContainer):
		fmt.Fprintln(out, "Creating portal")
		args := []string{
			"-d", "--name", PortalContainer,
			"--network", "mpd-internal:ip=" + n.IP(net.HostPortal),
			"--restart", "always",
		}
		args = append(args, podman.OptMountRO...)
		args = append(args,
			"-v", portalWWW+":/var/www/html:ro",
			"-v", vm.DataVolume+":/srv:ro",
			"-v", vm.StateDir+":/mpd-state:ro",
			"-v", renderedApache+":/etc/apache2/sites-available/mpd-portal.conf:ro",
			"-v", portalPHPIni+":/tmp/mpd-portal.ini:ro",
			"-v", vm.ServiceDir+"/cert.pem:/etc/mpd/cert.pem:ro",
			"-v", vm.ServiceDir+"/key.pem:/etc/mpd/key.pem:ro",
			"-v", vhostsDir+":/etc/apache2/mpd-vhosts:ro",
			"-v", certsDir+":/etc/mpd/certs:ro",
			"--label", "com.docker.compose.project=mpd-service",
			"--label", RevisionLabel+"="+portalRevision,
			"--label", CAFingerprintLabel+"="+caFingerprint,
			"docker.io/library/debian:trixie",
			"bash", "-c", portalSetupCmd,
		)
		if code, err := p.Run(ctx, args); err != nil || code != 0 {
			return fmt.Errorf("Failed to start %s.", PortalContainer)
		}
		ui.OK(out, "portal running.")
	case !p.Running(ctx, PortalContainer):
		if code, err := p.Start(ctx, PortalContainer); err != nil || code != 0 {
			return fmt.Errorf("Failed to start %s.", PortalContainer)
		}
		ui.OK(out, "portal running.")
	case proxyChanged:
		if code, err := p.Restart(ctx, PortalContainer); err != nil || code != 0 {
			return fmt.Errorf("Failed to reload %s after portal config update.", PortalContainer)
		}
		ui.OK(out, "Portal reloaded dynamic service vhosts.")
	default:
		ui.OK(out, "portal already running.")
	}
	return nil
}

// ensureProxyArtifacts renders one vhost and one certificate per proxied
// service, and removes the artifacts of services that no longer exist.
//
// Reports whether anything changed, so the caller restarts apache
// exactly once — or not at all, which is the usual case.
func ensureProxyArtifacts(ctx context.Context, n net.Net, templatePath, stateDir,
	vhostsDir, certsDir, caFingerprint string) (bool, error) {

	body, err := os.ReadFile(templatePath)
	if err != nil {
		return false, err
	}
	template := string(body)
	proxied := Proxied()

	changed := false

	wantVhost := map[string]bool{}
	wantCertDir := map[string]bool{}
	for _, d := range proxied {
		wantVhost[d.Name+".conf"] = true
		wantCertDir[d.Name] = true
	}
	removedStale, err := removeUnlisted(vhostsDir, wantVhost)
	if err != nil {
		return false, err
	}
	changed = changed || removedStale
	removedStale, err = removeUnlisted(certsDir, wantCertDir)
	if err != nil {
		return false, err
	}
	changed = changed || removedStale

	// One fingerprint file for the whole set: a new CA invalidates every
	// leaf at once, so they are regenerated together rather than each
	// being checked against the CA independently.
	fingerprintPath := filepath.Join(stateDir, "ca.fingerprint")
	stored := ""
	if data, err := os.ReadFile(fingerprintPath); err == nil {
		stored = strings.TrimSpace(string(data))
	}
	regenerateAll := stored != caFingerprint

	for _, d := range proxied {
		certDir := filepath.Join(certsDir, d.Name)
		if err := os.MkdirAll(certDir, 0o755); err != nil {
			return false, err
		}
		certPath := filepath.Join(certDir, "cert.pem")
		keyPath := filepath.Join(certDir, "key.pem")

		if regenerateAll || !exists(certPath) || !exists(keyPath) {
			if err := cert.Generate(ctx, []string{d.DNS(n)}, certPath, keyPath); err != nil {
				return false, err
			}
			changed = true
		}

		rendered := template
		for placeholder, value := range map[string]string{
			"{{SERVER_NAME}}":  d.DNS(n),
			"{{CERT_FILE}}":    "/etc/mpd/certs/" + d.Name + "/cert.pem",
			"{{KEY_FILE}}":     "/etc/mpd/certs/" + d.Name + "/key.pem",
			"{{UPSTREAM_URL}}": d.Proxy.UpstreamURL(d.IP(n)),
		} {
			rendered = strings.ReplaceAll(rendered, placeholder, value)
		}

		wrote, err := writeIfChanged(filepath.Join(vhostsDir, d.Name+".conf"), rendered)
		if err != nil {
			return false, err
		}
		changed = changed || wrote
	}

	if regenerateAll || stored == "" {
		if err := os.WriteFile(fingerprintPath, []byte(caFingerprint), 0o644); err != nil {
			return false, err
		}
	}
	return changed, nil
}

// removeUnlisted deletes entries in dir that are not in keep.
func removeUnlisted(dir string, keep map[string]bool) (bool, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false, nil
	}
	removed := false
	for _, e := range entries {
		if keep[e.Name()] {
			continue
		}
		if err := os.RemoveAll(filepath.Join(dir, e.Name())); err != nil {
			return removed, err
		}
		removed = true
	}
	return removed, nil
}

func writeIfChanged(path, content string) (bool, error) {
	if existing, err := os.ReadFile(path); err == nil && string(existing) == content {
		return false, nil
	}
	return true, os.WriteFile(path, []byte(content), 0o644)
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
