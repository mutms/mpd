package control

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func envFile(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "mpd-virt.env")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// The default has to be on, or the daemon would serve nothing on a VM whose
// env file simply says nothing about it.
func TestEnabledDefaultsOn(t *testing.T) {
	for name, path := range map[string]string{
		"missing file": filepath.Join(t.TempDir(), "absent.env"),
		"empty file":   envFile(t, ""),
		"unrelated":    envFile(t, "MPD_PHP_VERSION=8.4\n"),
		"commented":    envFile(t, "#MPD_RUNTIME_CONTROL=off\n"),
	} {
		if ok, _ := Enabled(path); !ok {
			t.Errorf("%s: should default to enabled", name)
		}
	}
}

func TestEnabledOffValues(t *testing.T) {
	for _, value := range []string{"off", "OFF", "false", "0", "no", " off ", `"off"`} {
		path := envFile(t, EnabledKey+"="+value+"\n")
		ok, why := Enabled(path)
		if ok {
			t.Errorf("%s=%q should disable", EnabledKey, value)
			continue
		}
		if !strings.Contains(why, EnabledKey) || !strings.Contains(why, "VM terminal") {
			t.Errorf("%s=%q: reason should name the key and the way out, got: %q",
				EnabledKey, value, why)
		}
	}
}

// A value nobody meant as "off" must not disable mpd inside every runtime.
func TestEnabledUnknownValueFailsTowardsWorking(t *testing.T) {
	for _, value := range []string{"on", "true", "1", "yes", "maybe", ""} {
		path := envFile(t, EnabledKey+"="+value+"\n")
		if ok, _ := Enabled(path); !ok {
			t.Errorf("%s=%q should not disable the feature", EnabledKey, value)
		}
	}
}

// Last occurrence wins, as the shell-side loader treats repeats.
func TestEnabledLastValueWins(t *testing.T) {
	if ok, _ := Enabled(envFile(t, EnabledKey+"=off\n"+EnabledKey+"=on\n")); !ok {
		t.Error("a later on should override an earlier off")
	}
	if ok, _ := Enabled(envFile(t, EnabledKey+"=on\n"+EnabledKey+"=off\n")); ok {
		t.Error("a later off should override an earlier on")
	}
}
