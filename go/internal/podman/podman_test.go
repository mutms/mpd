package podman

import (
	"context"
	"strings"
	"testing"

	"github.com/mutms/mpd/go/internal/exec"
)

// stub returns a Client whose runner records the args it was given and
// replays a canned result — so everything above this package is testable
// without podman installed.
func stub(out string, code int) (*Client, *[]string) {
	var got []string
	c := NewWith(func(ctx context.Context, args []string) (exec.Result, error) {
		got = args
		return exec.Result{Code: code, Stdout: out}, nil
	})
	return c, &got
}

const psJSON = `[
  {"Names":["mpd-service-dnsmasq"],"State":"running","Labels":{"mpd.managed":"true"}},
  {"Names":["mpd-service-portal"],"State":"exited","Labels":{"mpd.service.revision":"11"}},
  {"Names":["mpd-150-php-main"],"State":"running","Labels":null}
]`

func TestPsParsesPodmanJSON(t *testing.T) {
	c, args := stub(psJSON, 0)
	items := c.Ps(context.Background(), LabelManaged)
	if len(items) != 3 {
		t.Fatalf("got %d items, want 3", len(items))
	}
	if items[0].Name() != "mpd-service-dnsmasq" || items[0].State != "running" {
		t.Errorf("first item = %+v", items[0])
	}
	if got := items[1].Label("mpd.service.revision"); got != "11" {
		t.Errorf("label = %q, want %q", got, "11")
	}
	// A container with no labels must not panic.
	if got := items[2].Label("anything"); got != "" {
		t.Errorf("label on nil map = %q, want empty", got)
	}
	// Stopped containers must be included — `ps -a`, not `ps`.
	if !contains(*args, "-a") {
		t.Errorf("args = %v, want them to include -a", *args)
	}
	if !contains(*args, LabelManaged) {
		t.Errorf("args = %v, want them to include the filter", *args)
	}
}

// podman prints the literal "null" for an empty list; a failed call gives
// an empty string. Neither is an error — the honest answer is "none".
func TestPsEmptyForms(t *testing.T) {
	for _, out := range []string{"", "null", "[]"} {
		c, _ := stub(out, 0)
		if items := c.Ps(context.Background(), LabelManaged); len(items) != 0 {
			t.Errorf("Ps(%q) = %d items, want 0", out, len(items))
		}
	}
}

func TestPsNonZeroExitYieldsNoItems(t *testing.T) {
	c, _ := stub(psJSON, 1)
	if items := c.Ps(context.Background(), LabelManaged); len(items) != 0 {
		t.Errorf("got %d items on non-zero exit, want 0", len(items))
	}
}

func TestPsMalformedJSONYieldsNoItems(t *testing.T) {
	c, _ := stub("{not json", 0)
	if items := c.Ps(context.Background(), LabelManaged); len(items) != 0 {
		t.Errorf("got %d items for malformed JSON, want 0", len(items))
	}
}

func TestRunningIsExactMatch(t *testing.T) {
	c, _ := stub("true", 0)
	if !c.Running(context.Background(), "x") {
		t.Error("Running() = false for stdout \"true\"")
	}
	c, _ = stub("false", 0)
	if c.Running(context.Background(), "x") {
		t.Error("Running() = true for stdout \"false\"")
	}
}

// Network names contain hyphens, which breaks Go-template dot notation —
// the format string must use index notation with a quoted name.
func TestContainerIPUsesIndexNotation(t *testing.T) {
	c, args := stub("10.163.150.100", 0)
	ip := c.ContainerIP(context.Background(), "mpd-150-php-main", "mpd-internal")
	if ip != "10.163.150.100" {
		t.Errorf("ip = %q", ip)
	}
	joined := strings.Join(*args, " ")
	if !strings.Contains(joined, `index .NetworkSettings.Networks "mpd-internal"`) {
		t.Errorf("format = %q, want index notation with a quoted network name", joined)
	}
}

func TestNetworkSubnet(t *testing.T) {
	c, _ := stub("10.163.150.0/24", 0)
	if got := c.NetworkSubnet(context.Background(), "mpd-internal"); got != "10.163.150.0/24" {
		t.Errorf("NetworkSubnet() = %q", got)
	}
}

func contains(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}
