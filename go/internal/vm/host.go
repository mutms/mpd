package vm

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
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
	// uidmap provides newuidmap/newgidmap.
	//
	// Deliberately not aardvark-dns: mpd's network is created with
	// --disable-dns, so podman's own resolver is never started. It would
	// bind port 53 on the gateway, which is where mpd's resolver listens.
	{"podman", "/usr/bin/podman"},
	{"catatonit", "/usr/bin/catatonit"},
	{"uidmap", "/usr/bin/newuidmap"},
	{"nftables", "/usr/sbin/nft"},
	// WireGuard endpoint for the encrypted host↔VM overlay (mpd-virt/mpd-proxy):
	// wg-quick brings up wg0, wg generates and inspects keys. wireguard-go is
	// the userspace implementation wg-quick falls back to automatically when the
	// kernel has no WireGuard module — Apple containers run a lightweight VM
	// kernel that ships none, so wg0 there is userspace; the Parallels VMs use
	// the in-kernel module and leave wireguard-go installed but unused.
	{"wireguard-tools", "/usr/bin/wg"},
	{"wireguard-go", "/usr/bin/wireguard-go"},
	// The VM's resolver. dnsmasq-base is the binary alone; the `dnsmasq`
	// package would additionally install a second unit reading
	// /etc/dnsmasq.conf, which is the sysadmin's file and not mpd's.
	{"dnsmasq-base", "/usr/sbin/dnsmasq"},
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

// EnablePodmanRestart enables the unit that restarts containers marked
// --restart=always after a host reboot.
//
// Lives here rather than in bootstrap/40 because the unit ships with the
// podman package, which mpd installs itself — enabling it in a script
// that runs before mpd exists fails with "Unit podman-restart.service
// does not exist".
//
// Without it, --restart=always is silently ineffective across reboots:
// containers come back only when something starts them by hand.
func EnablePodmanRestart(ctx context.Context, out io.Writer) error {
	if unitIsActive(ctx, "podman-restart.service") {
		return nil
	}
	ui.Step(out, "podman-restart.service")
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "systemctl", Args: []string{"enable", "--now", "podman-restart.service"},
		Sudo: true,
	}); err != nil || code != 0 {
		return fmt.Errorf("Failed to enable podman-restart.service (exit %d).", code)
	}
	ui.OK(out, "podman-restart.service enabled.")
	return nil
}

// DisableGitHooks stops git hooks running on the VM. Two mechanisms,
// because one is not enough:
//
//  1. `git config --system core.hooksPath /dev/null`. Applies to every
//     git invocation regardless of shell or environment; git looks for
//     /dev/null/<hook>, gets ENOTDIR, and runs nothing. Surgical — it
//     edits one key rather than overwriting /etc/gitconfig.
//
//  2. GIT_CONFIG_* in /etc/environment. Needed because (1) LOSES to a
//     repository's own config, and the hooks worth stopping are exactly
//     the self-installing kind: husky (docusaurus, moodledev) writes
//     core.hooksPath into .git/config. These variables are applied as if
//     passed with `-c`, which outranks repo config. /etc/environment
//     rather than /etc/profile.d, because PAM applies it to `ssh vm
//     <cmd>` too, and profile.d only fires for login shells.
//
// VM only: runtime containers have their own /etc and keep hooks
// working, which is where a project's own tooling belongs. The VM has no
// node to run a JavaScript pre-commit hook with in any case.
//
// Escape hatch, for running a hook deliberately:
//
//	GIT_CONFIG_COUNT=0 git commit ...
func DisableGitHooks(ctx context.Context, out io.Writer) error {
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "git", Args: []string{"config", "--system", "core.hooksPath", "/dev/null"},
		Sudo: true,
	}); err != nil || code != 0 {
		return fmt.Errorf("Failed to set system core.hooksPath (exit %d).", code)
	}

	changed, err := mergeEnvironment(ctx, map[string]string{
		"GIT_CONFIG_COUNT":   "1",
		"GIT_CONFIG_KEY_0":   "core.hooksPath",
		"GIT_CONFIG_VALUE_0": "/dev/null",
	})
	if err != nil {
		return err
	}
	if changed {
		ui.OK(out, "git hooks disabled VM-wide (system config + /etc/environment).")
	}
	return nil
}

// mergeEnvironment sets keys in /etc/environment, leaving every other
// line alone.
//
// Merged rather than written: /etc/environment belongs to the machine,
// not to mpd, and a VM may well have entries from elsewhere.
func mergeEnvironment(ctx context.Context, want map[string]string) (bool, error) {
	const path = "/etc/environment"

	existing, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return false, err
	}

	var kept []string
	for _, line := range strings.Split(string(existing), "\n") {
		key, _, isAssignment := strings.Cut(line, "=")
		if isAssignment {
			if _, ours := want[strings.TrimSpace(key)]; ours {
				continue
			}
		}
		if strings.TrimSpace(line) != "" {
			kept = append(kept, line)
		}
	}

	for _, key := range sortedKeys(want) {
		kept = append(kept, key+"="+want[key])
	}
	body := strings.Join(kept, "\n") + "\n"

	if string(existing) == body {
		return false, nil
	}
	return WriteRootOwnedFile(ctx, path, body)
}

func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// RequireSystemdResolvedActive checks the one network-stack assumption
// mpd makes. The platform bootstrap scripts are responsible for putting
// the VM here; mpd only verifies and points at the fix.
func RequireSystemdResolvedActive(ctx context.Context, out io.Writer) error {
	if !unitIsActive(ctx, "systemd-resolved.service") {
		return fmt.Errorf(`systemd-resolved is not active. mpd VM standardizes on
systemd-networkd + systemd-resolved, which the prepare script sets up.

Most likely this VM has not been prepared (or a reboot was left
unfinished). Run the prepare script on the VM and follow its reboot
prompt until it reports ready:

    bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/setup/mpd-prepare-takeover.sh)

(For a self-contained sandbox, mpd-sandbox-setup.sh does the same and
then installs mpd.)`)
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

// ConfigureDNSResolver points systemd-resolved at mpd's resolver for the
// whole root domain, and makes this VM's own zone a search domain.
//
// Routing for the root domain, not this VM's zone: a VM has exactly one
// resolver and no business resolving another VM's zone, so NXDOMAIN for a
// foreign zone is the correct in-VM answer.
//
// The zone is additionally listed WITHOUT the `~`, which makes it a real
// search domain, so single-label names resolve here: `runtime` becomes
// runtime.<NNN>.mpd.test. That is what lets an SSH client reach the
// runtime by a name a human remembers — with ProxyJump the *jump host*
// resolves the target through libc, never through ~/.ssh/config, so the
// short ssh alias cannot serve that case and a resolvable name must.
// Publishing a bare `runtime` record in dnsmasq instead was rejected (see
// EnsureSSHConfig): a search domain is scoped to this VM's own resolution
// and never becomes an answer dnsmasq hands to containers.
//
// Cost is one extra query for unqualified names that are not ours;
// dnsmasq is authoritative for `.test` and answers NXDOMAIN immediately.
//
// `reload`, not `restart`, and only when the file actually changed —
// restarting drops the per-link DNS state resolved is already serving.
func ConfigureDNSResolver(ctx context.Context, out io.Writer, rootDomain, zone, resolverIP string) error {
	const path = "/etc/systemd/resolved.conf.d/mpd.conf"
	content := fmt.Sprintf("[Resolve]\nDNS=%s\nDomains=~%s %s\n", resolverIP, rootDomain, zone)

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
	ui.OK(out, "DNS resolver configured (systemd-resolved → %s for %s; search domain %s).",
		resolverIP, rootDomain, zone)
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

// InstallLoginBanner renders assets/vm/motd for this VM and makes
// it the static /etc/motd.
//
// Debian's update-motd.d scripts regenerate /etc/motd on login and would
// overwrite it, so they are disabled first. The banner names the portal
// URL, which is per-VM, hence a template rather than a shipped file.
func InstallLoginBanner(ctx context.Context, out io.Writer, zone string) error {
	source := AssetsDir + "/vm/motd"
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
	ui.OK(out, "/etc/motd installed from assets/vm/motd")
	return nil
}
