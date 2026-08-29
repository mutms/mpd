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

// RequireSupportedHost refuses to run on anything but Debian Trixie.
// Package names, toolchain and systemd defaults differ between releases,
// and off-release failures surface far from their cause.
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

// requiredPackages is a verification table, not an installer: the one
// package list is bootstrap/20-install-software.sh, and mpd never runs
// apt. A new run-time dependency is added there and here. Package and
// binary names differ (nft from nftables, rg from ripgrep), so both are
// named; /usr/bin/vim proves full vim rather than vim-tiny.
var requiredPackages = []struct{ Package, Binary string }{
	{"podman", "/usr/bin/podman"},
	{"catatonit", "/usr/bin/catatonit"},
	{"uidmap", "/usr/bin/newuidmap"},
	{"nftables", "/usr/sbin/nft"},
	{"wireguard-tools", "/usr/bin/wg"},
	{"wireguard-go", "/usr/bin/wireguard-go"},
	{"dnsmasq-base", "/usr/sbin/dnsmasq"},
	{"jq", "/usr/bin/jq"},
	{"caddy", "/usr/bin/caddy"},
	{"vim", "/usr/bin/vim"},
	{"git", "/usr/bin/git"},
	{"shellcheck", "/usr/bin/shellcheck"},
	{"shfmt", "/usr/bin/shfmt"},
	{"ripgrep", "/usr/bin/rg"},
	{"tree", "/usr/bin/tree"},
}

// bootstrapInstallScript installs or converges everything in
// requiredPackages.
const bootstrapInstallScript = MpdDir + "/bootstrap/20-install-software.sh"

// RequirePackages refuses to continue while a run-time dependency is
// missing, naming the packages and the script that installs them.
func RequirePackages() error {
	var missing []string
	for _, p := range requiredPackages {
		if info, err := os.Stat(p.Binary); err != nil || info.IsDir() {
			missing = append(missing, p.Package)
		}
	}
	if len(missing) == 0 {
		return nil
	}
	return fmt.Errorf("Missing packages: %s.\n"+
		"mpd does not install packages itself. Run the bootstrap step that does, then re-run mpd --vm-setup:\n"+
		"    bash %s", strings.Join(missing, ", "), bootstrapInstallScript)
}

// EnablePodmanRestart enables the packaged unit that restarts
// --restart=always containers after a reboot. Without it the flag is
// silently ineffective across reboots.
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

// DisableGitHooks stops git hooks running on the VM; runtimes keep their
// own hooks.
//
// Two mechanisms: system core.hooksPath=/dev/null covers every git
// invocation but loses to a repository's own config, which is what husky
// writes. GIT_CONFIG_* in /etc/environment outranks repo config, and PAM
// applies it to `ssh vm <cmd>` too, unlike profile.d.
// To run a hook deliberately: GIT_CONFIG_COUNT=0 git commit ...
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
// line alone: the file belongs to the machine, not to mpd.
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

func unitIsActive(ctx context.Context, unit string) bool {
	code, err := exec.Run(ctx, exec.Cmd{
		Name: "systemctl", Args: []string{"is-active", "--quiet", unit},
	})
	return err == nil && code == 0
}

// WriteRootOwnedFile installs content at a root-owned path via sudo,
// reporting whether anything changed. An identical file short-circuits
// before sudo runs. The replacement is staged then renamed: `install`
// alone leaves an instant with no file, which /etc/hosts readers would
// see.
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
	staged := path + ".mpd-tmp"
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "install", Args: []string{"-D", "-m", "644", tmp.Name(), staged}, Sudo: true,
	}); err != nil || code != 0 {
		return false, fmt.Errorf("Failed to install %s.", path)
	}
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "mv", Args: []string{"-f", staged, path}, Sudo: true,
	}); err != nil || code != 0 {
		return false, fmt.Errorf("Failed to replace %s.", path)
	}
	return true, nil
}

// InstallLoginBanner renders assets/vm/motd and installs it as /etc/motd.
// Debian's update-motd.d scripts would overwrite it on login, so they
// are disabled first.
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
