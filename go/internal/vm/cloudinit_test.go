package vm

import (
	"os"
	"strings"
	"testing"
)

// The drop-in is a copy of Debian trixie's cloud_init_modules list with
// exactly one module removed. Pinned here so an edit that drops a second
// module — or reintroduces the one this exists to remove — fails in CI
// rather than on a VM at boot.
func TestCloudInitDropInAsset(t *testing.T) {
	body, err := os.ReadFile("../../../assets/vm/cloud-init-99-mpd.cfg")
	if err != nil {
		t.Fatal(err)
	}
	asset := string(body)

	if strings.Contains(asset, "update_etc_hosts") && !strings.Contains(asset, "without update_etc_hosts") {
		t.Error("the module this drop-in exists to remove is listed")
	}
	var modules []string
	for _, line := range strings.Split(asset, "\n") {
		if strings.HasPrefix(line, " - ") {
			modules = append(modules, strings.TrimPrefix(line, " - "))
		}
	}
	// trixie's cloud.cfg (cloud-init 25.1) lists fourteen; minus one.
	want := []string{"seed_random", "bootcmd", "write-files", "growpart", "resizefs",
		"disk_setup", "mounts", "set_hostname", "update_hostname", "ca-certs",
		"rsyslog", "users-groups", "ssh"}
	if strings.Join(modules, ",") != strings.Join(want, ",") {
		t.Errorf("module list drifted from trixie's cloud.cfg minus update_etc_hosts:\n got %v\nwant %v", modules, want)
	}
	if !strings.Contains(asset, "\ncloud_init_modules:\n") {
		t.Error("the list must be under the cloud_init_modules key to replace cloud.cfg's")
	}
}
