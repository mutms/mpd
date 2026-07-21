package vm

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/ui"
)

// OSRelease is the subset of /etc/os-release mpd gates on.
type OSRelease struct {
	ID       string
	Codename string
}

// ParseOSRelease reads the bash-ish KEY=VALUE format, unquoting values.
// Missing keys come back empty; the caller decides what that means.
func ParseOSRelease(body string) OSRelease {
	var os OSRelease
	for _, raw := range strings.Split(body, "\n") {
		key, value, found := strings.Cut(strings.TrimSpace(raw), "=")
		if !found {
			continue
		}
		if len(value) >= 2 && strings.HasPrefix(value, `"`) && strings.HasSuffix(value, `"`) {
			value = value[1 : len(value)-1]
		}
		switch key {
		case "ID":
			os.ID = value
		case "VERSION_CODENAME":
			os.Codename = value
		}
	}
	return os
}

// RequireSupportedHost is a hard gate on Debian Trixie.
//
// Not conservatism for its own sake: package names, Go toolchain
// availability, the systemd unit layout and systemd-resolved's defaults
// all differ between releases, and mpd drives all four. Running on
// anything else produces failures far from their cause, so the check is
// up front and refuses rather than warns.
func RequireSupportedHost() error {
	body, err := os.ReadFile("/etc/os-release")
	if err != nil {
		return fmt.Errorf("Cannot read /etc/os-release. mpd targets Debian Trixie.")
	}
	rel := ParseOSRelease(string(body))
	if rel.ID != "debian" {
		return fmt.Errorf("mpd targets Debian (got ID=%s).\n"+
			"Use a Debian Trixie VM and re-run mpd --vm-setup.", rel.ID)
	}
	if rel.Codename != "trixie" {
		return fmt.Errorf("mpd targets Debian Trixie (got VERSION_CODENAME=%s).\n"+
			"Package names, Go toolchain, and systemd-resolved/systemd-networkd\n"+
			"defaults vary between releases — pin to Trixie or accept that\n"+
			"you're off the supported path.", rel.Codename)
	}
	return nil
}

// bootstrapBinaries are representative of what
// bootstrap/40-install-software.sh installs. Checking a handful of stats
// is enough to tell "bootstrap never ran" from "bootstrap ran" — the
// case this guards against is a fresh VM where --vm-setup was typed too
// early, not a hand-broken one.
var bootstrapBinaries = []struct{ Name, Path string }{
	{"podman", "/usr/bin/podman"},
	{"nft", "/usr/sbin/nft"},
	{"jq", "/usr/bin/jq"},
	{"dig", "/usr/bin/dig"},
}

// RequireBootstrapCompleted verifies the apt phase of bootstrap ran, and
// names the missing pieces plus the commands that install them.
func RequireBootstrapCompleted() error {
	var missing []string
	for _, b := range bootstrapBinaries {
		info, err := os.Stat(b.Path)
		if err != nil || info.IsDir() || info.Mode().Perm()&0o111 == 0 {
			missing = append(missing, b.Name)
		}
	}
	if len(missing) == 0 {
		return nil
	}
	return fmt.Errorf("Bootstrap incomplete — missing: %s.\n"+
		"Run the bootstrap steps in /opt/mpd/bootstrap/:\n"+
		"    bash bootstrap/30-networking.sh <NNN>      # sandbox: 000; managed: 100..254\n"+
		"    bash bootstrap/40-install-software.sh\n"+
		"    bash bootstrap/50-build.sh",
		strings.Join(missing, ", "))
}

// RequireSystemdResolvedActive checks the one network-stack assumption
// mpd makes. The platform bootstrap scripts are responsible for putting
// the VM here; mpd only verifies and points at the fix.
func RequireSystemdResolvedActive(ctx context.Context, out io.Writer) error {
	if !unitIsActive(ctx, "systemd-resolved.service") {
		return fmt.Errorf(`systemd-resolved is not active. mpd VM standardizes on
systemd-resolved as the host DNS sink on every supported
install profile.

If your VM was just rebooted-in-place mid-provision, finish the
reboot first:

    sudo reboot

Then SSH back in and re-run mpd --vm-setup.

Otherwise, see the README of your platform under
/opt/mpd/setup/ for the expected network stack.`)
	}
	ui.OK(out, "systemd-resolved is active.")
	return nil
}

func unitIsActive(ctx context.Context, unit string) bool {
	code, err := exec.Run(ctx, exec.Cmd{
		Name: "systemctl", Args: []string{"is-active", "--quiet", unit},
	})
	return err == nil && code == 0
}

// ConfigureDNSResolver points systemd-resolved at the dnsmasq container
// for the whole root domain.
//
// The root domain, not this VM's zone: a VM has exactly one dnsmasq and
// no business resolving another VM's zone, so NXDOMAIN for a foreign
// zone is the correct in-VM answer.
//
// `reload`, not `restart`, and only when the file actually changed —
// restarting drops the per-link DNS state resolved is already serving.
func ConfigureDNSResolver(ctx context.Context, out io.Writer, rootDomain, dnsmasqIP string) error {
	const path = "/etc/systemd/resolved.conf.d/mpd.conf"
	content := fmt.Sprintf("[Resolve]\nDNS=%s\nDomains=~%s\n", dnsmasqIP, rootDomain)

	changed, err := WriteRootOwnedFile(ctx, path, content)
	if err != nil {
		return err
	}
	if changed {
		if code, err := exec.Run(ctx, exec.Cmd{
			Name: "systemctl", Args: []string{"reload", "systemd-resolved"}, Sudo: true,
		}); err != nil || code != 0 {
			return fmt.Errorf("systemctl reload systemd-resolved failed.")
		}
	}
	ui.OK(out, "DNS resolver configured (systemd-resolved → %s for %s).", dnsmasqIP, rootDomain)
	return nil
}

// WriteRootOwnedFile installs content at a root-owned path via sudo,
// reporting whether anything changed. An identical file short-circuits
// before sudo runs, so a repeat `--vm-setup` neither writes nor prompts.
func WriteRootOwnedFile(ctx context.Context, path, content string) (bool, error) {
	if existing, err := os.ReadFile(path); err == nil && string(existing) == content {
		return false, nil
	}
	tmp, err := os.CreateTemp("", "mpd-conf-*")
	if err != nil {
		return false, err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(content); err != nil {
		tmp.Close()
		return false, err
	}
	if err := tmp.Close(); err != nil {
		return false, err
	}
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "install", Args: []string{"-D", "-m", "644", tmp.Name(), path}, Sudo: true,
	}); err != nil || code != 0 {
		return false, fmt.Errorf("Failed to install %s.", path)
	}
	return true, nil
}

// InstallLoginBanner renders assets/machine/motd for this VM and makes
// it the static /etc/motd.
//
// Debian's update-motd.d scripts regenerate /etc/motd on login and would
// overwrite it, so they are disabled first. The banner names the portal
// URL, which is per-VM, hence a template rather than a shipped file.
func InstallLoginBanner(ctx context.Context, out io.Writer, zone string) error {
	source := AssetsDir + "/machine/motd"
	template, err := os.ReadFile(source)
	if err != nil {
		return fmt.Errorf("motd asset missing: %s", source)
	}

	// Best-effort: the directory does not exist on every image.
	_, _ = exec.Run(ctx, exec.Cmd{
		Name: "bash",
		Args: []string{"-c", "chmod -x /etc/update-motd.d/* 2>/dev/null || true"},
		Sudo: true,
	})

	rendered := strings.ReplaceAll(string(template), "%%ZONE%%", zone)
	staged := filepath.Join(os.TempDir(), "mpd-motd")
	if err := os.WriteFile(staged, []byte(rendered), 0o644); err != nil {
		return err
	}
	defer os.Remove(staged)

	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "install", Args: []string{"-m", "644", staged, "/etc/motd"}, Sudo: true,
	}); err != nil || code != 0 {
		return fmt.Errorf("Failed to install /etc/motd from %s.", source)
	}
	ui.OK(out, "/etc/motd installed from assets/machine/motd")
	return nil
}
