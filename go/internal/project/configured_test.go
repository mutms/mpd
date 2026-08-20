package project

import (
	"strings"
	"testing"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/state"
)

func testNet(t *testing.T, octet int) net.Net {
	t.Helper()
	n, err := net.New(octet)
	if err != nil {
		t.Fatalf("net.New(%d): %v", octet, err)
	}
	return n
}

func urls(list ...string) []state.ProjectURL {
	out := make([]state.ProjectURL, 0, len(list))
	for _, u := range list {
		out = append(out, state.ProjectURL{Label: "main", Kind: "web", URL: u})
	}
	return out
}

// The ordinary case: a project configured on this VM starts.
func TestCheckConfiguredAcceptsInZoneURLs(t *testing.T) {
	err := CheckConfigured("m45", urls(
		"https://m45.150.mpd.test/",
		"https://mail.m45.150.mpd.test/",
	), testNet(t, 150))
	if err != nil {
		t.Errorf("in-zone project rejected: %v", err)
	}
}

// No URLs is a valid configuration, not a broken one — a bare or cftunnel
// project publishes none. Rejecting it would make those types unstartable.
func TestCheckConfiguredAcceptsAProjectWithNoURLs(t *testing.T) {
	if err := CheckConfigured("tunnel", nil, testNet(t, 150)); err != nil {
		t.Errorf("project with no URLs rejected: %v", err)
	}
	if err := CheckConfigured("tunnel", urls(), testNet(t, 150)); err != nil {
		t.Errorf("project with an empty URL list rejected: %v", err)
	}
}

// The case this exists for: /srv restored from another VM, or MPD_VM_ID
// changed. Nothing mpd can repair without re-running configure.sh, so it
// must refuse rather than quietly issue certs and DNS for names that
// belong to a different VM.
func TestCheckConfiguredRejectsAnotherVMsZone(t *testing.T) {
	err := CheckConfigured("m45", urls("https://m45.150.mpd.test/"), testNet(t, 180))
	if err == nil {
		t.Fatal("project from another VM's zone accepted")
	}
	// The message has to carry both zones and the remedy, or it sends the
	// reader looking in the wrong place.
	for _, want := range []string{"m45.150.mpd.test", "180.mpd.test", "mpd start m45"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error does not mention %q:\n%s", want, err)
		}
	}
}

// A project with one in-zone URL is usable even if another URL points
// outside — a cftunnel project publishes a public hostname deliberately.
func TestCheckConfiguredAcceptsAMixWithAtLeastOneInZone(t *testing.T) {
	err := CheckConfigured("m45", urls(
		"https://m45.150.mpd.test/",
		"https://m45.example.com/",
	), testNet(t, 150))
	if err != nil {
		t.Errorf("project with a public tunnel URL rejected: %v", err)
	}
}

// Zone matching is on the full zone, not the root domain: another VM's
// project is out of zone even though it is under mpd.test.
func TestCheckConfiguredIsScopedToTheZoneNotTheRootDomain(t *testing.T) {
	if err := CheckConfigured("m45", urls("https://m45.mpd.test/"), testNet(t, 150)); err == nil {
		t.Error("a bare mpd.test URL was accepted as in-zone")
	}
}
