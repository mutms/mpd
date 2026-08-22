package vm

import (
	"context"
	"fmt"
	"io"
	"os"

	"github.com/mutms/mpd/go/internal/ui"
)

// cloud-init on an adopted box.
//
// Its first boot may run everything; after mpd is set up the box's
// identity is fixed — hostname, dev user, the SSH host keys mpd-virt
// pinned, and /etc/hosts, which holds mpd's DNS records. cloud-init
// would keep touching all of it: update_etc_hosts rewrites /etc/hosts on
// every boot (the seed says `manage_etc_hosts: true`, which Proxmox
// always writes and user-data outranks anything under /etc/cloud/), and
// Proxmox issues a new instance-id whenever its cloud-init tab is edited,
// which re-runs every per-instance module on the next boot — hostname,
// users, and ssh, which regenerates the host keys.
//
// cloud-init's own override for module lists is the fix: a cloud.cfg.d
// drop-in that restates a stage's list replaces it wholesale, and
// user-data never sets one. The drop-in is a static asset — mpd supports
// one distro — leaving only growpart + resizefs, so enlarging the disk in
// the hypervisor still works; network config is not a module and keeps
// applying, so fixing the IP there works too.
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
