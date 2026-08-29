package vm

import (
	"os"
	"strings"
	"testing"
)

// The drop-in must leave cloud-init only the disk modules. An identity
// module let back in would break a VM at boot, so it fails here instead.
func TestCloudInitDropInAsset(t *testing.T) {
	body, err := os.ReadFile("../../../assets/vm/cloud-init-99-mpd.cfg")
	if err != nil {
		t.Fatal(err)
	}
	asset := string(body)

	for _, banned := range []string{"update_etc_hosts", "set_hostname", "update_hostname", "users-groups", "ssh"} {
		if strings.Contains(asset, " - "+banned) {
			t.Errorf("identity module %s is listed", banned)
		}
	}
	var modules []string
	for _, line := range strings.Split(asset, "\n") {
		if strings.HasPrefix(line, " - ") {
			modules = append(modules, strings.TrimPrefix(line, " - "))
		}
	}
	want := []string{"growpart", "resizefs"}
	if strings.Join(modules, ",") != strings.Join(want, ",") {
		t.Errorf("module list drifted:\n got %v\nwant %v", modules, want)
	}
	for _, key := range []string{"\ncloud_init_modules:\n", "\ncloud_config_modules: []\n", "\ncloud_final_modules: []\n"} {
		if !strings.Contains(asset, key) {
			t.Errorf("missing %q — every stage's list must be replaced", strings.TrimSpace(key))
		}
	}
}
