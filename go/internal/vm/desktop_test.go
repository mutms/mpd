package vm

import (
	"strings"
	"testing"
)

func TestChromiumHomepagePolicy(t *testing.T) {
	got, err := ChromiumHomepagePolicy("191.mpd.test")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		`"HomepageLocation": "https://191.mpd.test/"`,
		`"RestoreOnStartup": 4`,
		`"https://191.mpd.test/"`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("policy lacks %s:\n%s", want, got)
		}
	}
	again, _ := ChromiumHomepagePolicy("191.mpd.test")
	if got != again {
		t.Error("policy is not deterministic, so the already-set check would never hold")
	}
}

func TestHasLine(t *testing.T) {
	if !hasLine("user-db:user\nsystem-db:local\n", "system-db:local") {
		t.Error("want the line found")
	}
	if hasLine("user-db:user\n# system-db:local\n", "system-db:local") {
		t.Error("a commented line must not count")
	}
}
