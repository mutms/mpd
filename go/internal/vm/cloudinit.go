package vm

import (
	"context"
	"fmt"
	"io"
	"os"

	"github.com/mutms/mpd/go/internal/ui"
)

// cloud-init would keep rewriting the VM's fixed identity on later boots:
// /etc/hosts, hostname, users, and the SSH host keys. The drop-in
// replaces every stage's module list, leaving only growpart and resizefs.
// See docs/debugging.md.
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
