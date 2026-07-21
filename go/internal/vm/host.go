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

// requiredPackages is what mpd itself needs at run time, keyed by a
// binary whose absence proves the package is missing.
//
// bootstrap/40 installs the other half: what is needed to configure and
// diagnose networking and to build mpd (golang-go, git, iproute2,
// bind9-dnsutils, jq, …). The split is by purpose — that script runs
// once before mpd exists, this list converges on every `--vm-setup`, so
// a new runtime dependency reaches an already-bootstrapped VM without
// re-running bootstrap.
//
// Package name and binary name are not the same thing — nft comes from
// nftables, newuidmap from uidmap — so both are named rather than
// derived.
var requiredPackages = []struct{ Package, Binary string }{
	// Container engine and the pieces podman needs but does not pull in
	// under --no-install-recommends: catatonit is the pod pause binary,
	// aardvark-dns resolves container names (without it `--dns` on a
	// podman network is silently dropped), uidmap provides
	// newuidmap/newgidmap.
	{"podman", "/usr/bin/podman"},
	{"catatonit", "/usr/bin/catatonit"},
	{"aardvark-dns", "/usr/lib/podman/aardvark-dns"},
	{"uidmap", "/usr/bin/newuidmap"},
	{"nftables", "/usr/sbin/nft"},
	// Also in bootstrap/40, deliberately: the bootstrap scripts need it
	// before mpd exists, and repeating it here keeps it converging on a
	// VM bootstrapped earlier. mpd itself never shells out to jq — it
	// parses JSON in Go, and jq is not on the internal/exec allow-list —
	// but `bin/demo` uses it, and so does anyone reading /srv/meta by
	// hand.
	{"jq", "/usr/bin/jq"},
	{"caddy", "/usr/bin/caddy"}, // TLS frontdoor for `mpd --web`
	// Full vim, not vim-tiny: vim-tiny ships no defaults.vim, so it
	// starts in compatible mode where arrow keys insert ABCD and
	// backspace will not cross the insert point. /usr/bin/vim is the
	// proof — vim-tiny provides only /usr/bin/vi.
	{"vim", "/usr/bin/vim"},

	// Extra tools for AI agents. An agent working on the VM is otherwise
	// worse equipped than one inside a runtime, which already ships a
	// developer toolbox — and project setup now happens VM-side.
	// shellcheck/shfmt matter most: mpd is ~70 shell files with no
	// linting, so this is the only thing that checks them.
	//
	// Deliberately not `gh`: it does nothing until `gh auth login`, and
	// that stores a token on the VM. mpd keeps no credentials — git auth
	// is the developer's SSH agent — and the CI side of this project is
	// forgejo, not GitHub. Anyone who wants it: `sudo apt install gh`.
	{"shellcheck", "/usr/bin/shellcheck"},
	{"shfmt", "/usr/bin/shfmt"},
	{"ripgrep", "/usr/bin/rg"}, // fast search over big project trees
	{"tree", "/usr/bin/tree"},
}

// EnsurePackages installs whatever is missing.
//
// No "you must run bootstrap first" branch: mpd runs on Debian and can
// install its own dependencies. The distinction only ever existed when
// mpd was meant to run on macOS too, where it could not.
func EnsurePackages(ctx context.Context, out io.Writer) error {
	var missing []string
	for _, p := range requiredPackages {
		if info, err := os.Stat(p.Binary); err != nil || info.IsDir() {
			missing = append(missing, p.Package)
		}
	}
	if len(missing) == 0 {
		return nil
	}

	ui.Step(out, "Installing %s", strings.Join(missing, ", "))
	// Refresh the index first: on a VM whose lists are empty or stale,
	// install fails with "Unable to locate package", which reads like a
	// missing package rather than a missing index.
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "apt-get", Args: []string{"update", "-qq"},
		Env: []string{"DEBIAN_FRONTEND=noninteractive"}, Sudo: true,
	}); err != nil || code != 0 {
		return fmt.Errorf("apt-get update failed (exit %d).", code)
	}
	args := append([]string{"install", "-y", "--no-install-recommends"}, missing...)
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "apt-get", Args: args,
		Env: []string{"DEBIAN_FRONTEND=noninteractive"}, Sudo: true,
	}); err != nil || code != 0 {
		return fmt.Errorf("Failed to install %s (apt-get exit %d).",
			strings.Join(missing, ", "), code)
	}
	ui.OK(out, "installed %s", strings.Join(missing, ", "))
	return nil
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
