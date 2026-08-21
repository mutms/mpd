package vm

import (
	"context"
	"fmt"
	"io"
	"os"

	"github.com/mutms/mpd/go/internal/ui"
)

// cloud-init and /etc/hosts.
//
// On a cloud-init image the seed's user-data usually says
// `manage_etc_hosts: true` — Proxmox always writes it, and it cannot be
// switched off in its UI. That makes cloud-init's update_etc_hosts module
// rewrite /etc/hosts from a template on EVERY boot, which would wipe mpd's
// records until the next reconcile.
//
// The obvious fix does not work: `manage_etc_hosts: false` anywhere under
// /etc/cloud/ is outranked by the instance user-data, which cloud-init
// caches and reuses on every boot. What does work is cloud-init's own
// override mechanism for module lists: a cloud.cfg.d drop-in that restates
// cloud_init_modules replaces the list wholesale, and user-data never sets
// one. The drop-in is a static asset — mpd supports one distro, so the
// list is a known constant — with update_etc_hosts left out. Every other
// module keeps running.
const (
	cloudInitDir        = "/etc/cloud"
	cloudInitDropInPath = cloudInitDir + "/cloud.cfg.d/99-mpd.cfg"
	cloudInitAsset      = AssetsDir + "/vm/cloud-init-99-mpd.cfg"
)

// DisableCloudInitHosts installs the drop-in on a VM that has cloud-init,
// and does nothing on one that has not.
func DisableCloudInitHosts(ctx context.Context, out io.Writer) error {
	if _, err := os.Stat(cloudInitDir); err != nil {
		ui.OK(out, "No cloud-init on this VM — nothing rewrites /etc/hosts at boot.")
		return nil
	}
	body, err := os.ReadFile(cloudInitAsset)
	if err != nil {
		return fmt.Errorf("cloud-init drop-in asset missing: %s", cloudInitAsset)
	}
	changed, err := WriteRootOwnedFile(ctx, cloudInitDropInPath, string(body))
	if err != nil {
		return err
	}
	if changed {
		ui.OK(out, "cloud-init will no longer rewrite /etc/hosts (%s).", cloudInitDropInPath)
	} else {
		ui.OK(out, "cloud-init leaves /etc/hosts alone (%s).", cloudInitDropInPath)
	}
	return nil
}
