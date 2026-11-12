package vm

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/ui"
)

// Desktop defaults for the GNOME desktop that provisioning installs.
// Both are defaults, not locks: a value the user sets in the desktop
// wins. Failures warn rather than abort, like the trust stores.
const (
	chromiumPolicyPath = "/etc/chromium/policies/recommended/mpd-homepage.json"
	dconfProfilePath   = "/etc/dconf/profile/user"
	dconfDockPath      = "/etc/dconf/db/local.d/00-mpd-dock"
)

const dconfProfile = "user-db:user\nsystem-db:local\n"

// dconfDock shows the dock on the left, always visible, as Ubuntu does,
// with Settings, Terminal and Chromium pinned.
const dconfDock = `# Managed by mpd --vm-setup.
[org/gnome/shell]
enabled-extensions=['dash-to-dock@micxgx.gmail.com']
favorite-apps=['org.gnome.Settings.desktop', 'org.gnome.Terminal.desktop', 'chromium.desktop']

[org/gnome/shell/extensions/dash-to-dock]
dock-position='LEFT'
dock-fixed=true
extend-height=true
`

// ChromiumHomepagePolicy renders the policy that points Chromium at this
// VM's portal. It lives in policies/recommended, which leaves the setting
// editable; managed/ would lock it.
func ChromiumHomepagePolicy(zone string) (string, error) {
	url := "https://" + zone + "/"
	data, err := json.MarshalIndent(map[string]any{
		"HomepageLocation":     url,
		"HomepageIsNewTabPage": false,
		"ShowHomeButton":       true,
		"RestoreOnStartup":     4,
		"RestoreOnStartupURLs": []string{url},
	}, "", "  ")
	if err != nil {
		return "", err
	}
	return string(data) + "\n", nil
}

// InstallChromiumHomepage makes the VM's portal Chromium's home and
// startup page.
func InstallChromiumHomepage(ctx context.Context, out io.Writer, zone string) {
	policy, err := ChromiumHomepagePolicy(zone)
	if err != nil {
		ui.Warn(out, "failed to serialize the Chromium policy: %v", err)
		return
	}
	changed, err := installRootFile(ctx, chromiumPolicyPath, policy)
	switch {
	case err != nil:
		ui.Warn(out, "failed to write %s.", chromiumPolicyPath)
	case changed:
		ui.OK(out, "Chromium home page set to https://%s/.", zone)
	default:
		ui.OK(out, "Chromium home page already set.")
	}
}

// InstallDockDefaults switches Dash to Dock on through system dconf
// defaults. Skipped on a VM without dconf, which has no desktop.
func InstallDockDefaults(ctx context.Context, out io.Writer) {
	if !exec.Available("dconf") {
		ui.OK(out, "no dconf here — dock skipped.")
		return
	}

	// The dock file is only read when the user profile names the local
	// database. Create the profile when it is missing; leave one that
	// someone else wrote alone.
	if existing, err := os.ReadFile(dconfProfilePath); err != nil {
		if _, err := installRootFile(ctx, dconfProfilePath, dconfProfile); err != nil {
			ui.Warn(out, "failed to write %s.", dconfProfilePath)
			return
		}
	} else if !hasLine(string(existing), "system-db:local") {
		ui.Warn(out, "%s does not read system-db:local — leaving the dock at GNOME's default.", dconfProfilePath)
		return
	}

	changed, err := installRootFile(ctx, dconfDockPath, dconfDock)
	if err != nil {
		ui.Warn(out, "failed to write %s.", dconfDockPath)
		return
	}
	if !changed {
		ui.OK(out, "dock defaults already in place.")
		return
	}
	if code, err := exec.Run(ctx, exec.Cmd{Name: "dconf", Args: []string{"update"}, Sudo: true}); err != nil || code != 0 {
		ui.Warn(out, "dconf update failed — the dock defaults are not active yet.")
		return
	}
	ui.OK(out, "dock on the left by default — log out and in again to see it.")
}

// installRootFile writes content to a root-owned path, mode 644, creating
// its directory. It reports whether the file changed.
func installRootFile(ctx context.Context, path, content string) (bool, error) {
	if existing, err := os.ReadFile(path); err == nil && string(existing) == content {
		return false, nil
	}
	staged, err := os.CreateTemp("", "mpd-"+filepath.Base(path)+"-*")
	if err != nil {
		return false, err
	}
	defer os.Remove(staged.Name())
	if _, err := staged.WriteString(content); err != nil {
		staged.Close()
		return false, err
	}
	if err := staged.Close(); err != nil {
		return false, err
	}
	code, err := exec.Run(ctx, exec.Cmd{
		Name: "install", Args: []string{"-D", "-m", "644", staged.Name(), path}, Sudo: true,
	})
	if err != nil {
		return false, err
	}
	if code != 0 {
		return false, os.ErrPermission
	}
	return true, nil
}

// hasLine reports whether text contains line as a whole line.
func hasLine(text, line string) bool {
	for _, l := range strings.Split(text, "\n") {
		if strings.TrimSpace(l) == line {
			return true
		}
	}
	return false
}
