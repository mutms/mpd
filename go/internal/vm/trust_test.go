package vm

import (
	"encoding/json"
	"strings"
	"testing"
)

// The policy file is compared byte for byte to decide whether to rewrite
// it, so the rendering has to be stable across runs. Go sorts map keys
// when marshalling; this pins that property rather than assuming it.
func TestFirefoxPolicyIsDeterministic(t *testing.T) {
	first, err := FirefoxPolicy("/etc/firefox/policies/mpd-rootCA.crt", "150.mpd.test")
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 20; i++ {
		again, err := FirefoxPolicy("/etc/firefox/policies/mpd-rootCA.crt", "150.mpd.test")
		if err != nil {
			t.Fatal(err)
		}
		if again != first {
			t.Fatalf("rendering %d differs:\n%s\n---\n%s", i, first, again)
		}
	}
}

func TestFirefoxPolicyContent(t *testing.T) {
	body, err := FirefoxPolicy("/usr/local/share/ca-certificates/mpd-local.crt", "150.mpd.test")
	if err != nil {
		t.Fatal(err)
	}

	var parsed struct {
		Policies struct {
			Certificates struct {
				Install []string
			}
			Homepage struct {
				URL       string
				Locked    bool
				StartPage string
			}
		}
	}
	if err := json.Unmarshal([]byte(body), &parsed); err != nil {
		t.Fatalf("policy is not valid JSON: %v\n%s", err, body)
	}

	if got := parsed.Policies.Certificates.Install; len(got) != 1 ||
		got[0] != "/usr/local/share/ca-certificates/mpd-local.crt" {
		t.Errorf("Certificates.Install = %v", got)
	}
	if got := parsed.Policies.Homepage.URL; got != "https://150.mpd.test/" {
		t.Errorf("Homepage.URL = %q", got)
	}
	// Not locked on purpose: a developer who prefers their own Moodle
	// as the landing page must be able to say so.
	if parsed.Policies.Homepage.Locked {
		t.Error("Homepage.Locked = true, want the user to be able to override it")
	}
	if !strings.HasSuffix(body, "\n") {
		t.Error("policy file does not end in a newline")
	}
}

// The unit's whole purpose is the shutdown half; a regression that drops
// ExecStop, or that makes a failed boot-time start fatal (losing
// ExecStop with it), silently costs every database a clean shutdown.
func TestUnitKeepsTheGracefulStopPath(t *testing.T) {
	body := UnitBody("/opt/mpd/bin/mpd")
	for _, want := range []string{
		"ExecStop=/opt/mpd/bin/mpd --vm-stop",
		"ExecStart=-/opt/mpd/bin/mpd --vm-start",
		"Before=shutdown.target reboot.target halt.target suspend.target",
		"RemainAfterExit=yes",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("unit is missing %q:\n%s", want, body)
		}
	}
}
