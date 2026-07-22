package cli

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
)

// Column padding must match Swift's helper exactly, including the
// over-width case: Swift appends two spaces rather than truncating, so a
// long name pushes the row instead of losing characters.
func TestCol(t *testing.T) {
	if got := Col("php", 14); got != "php           " {
		t.Errorf("Col(short) = %q (len %d)", got, len(got))
	}
	if got := Col("exactly-14-chr", 14); got != "exactly-14-chr  " {
		t.Errorf("Col(exact width) = %q, want two trailing spaces", got)
	}
	if got := Col("a-very-long-service-name", 14); got != "a-very-long-service-name  " {
		t.Errorf("Col(over width) = %q, want the name intact plus two spaces", got)
	}
}

// Output is piped in tests, so colour must be off — otherwise escape
// codes would break the diff against the Swift binary.
func TestStatusLabelIsPlainWhenNotATerminal(t *testing.T) {
	got := StatusLabel(StatusRunning, colStatus)
	if strings.Contains(got, "\033[") {
		t.Errorf("StatusLabel = %q, want no ANSI escapes when piped", got)
	}
	if got != "running     " {
		t.Errorf("StatusLabel = %q, want padded to %d", got, colStatus)
	}
}

func testNet(t *testing.T, octet int) net.Net {
	t.Helper()
	n, err := net.New(octet)
	if err != nil {
		t.Fatalf("net.New: %v", err)
	}
	return n
}

func stubPodman(psJSON string) *podman.Client {
	return podman.NewWith(func(ctx context.Context, args []string) (exec.Result, error) {
		return exec.Result{Code: 0, Stdout: psJSON}, nil
	})
}

func TestListServices(t *testing.T) {
	// Only adminer is a container now; the resolver and the status page
	// are systemd units on the VM. Reported as not-created, which is what
	// an empty podman ps means for the one service that is still a
	// container.
	ps := `[]`
	var buf bytes.Buffer
	// dnsmasq and the portal are systemd-backed; report them running
	// without a systemd in the loop.
	unitActive := func(context.Context, string, bool) bool { return true }
	ListServices(context.Background(), &buf, testNet(t, 150), stubPodman(ps), unitActive)
	out := buf.String()

	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if len(lines) != 5 { // header + rule + 3 services
		t.Fatalf("got %d lines, want 5:\n%s", len(lines), out)
	}
	if !strings.HasPrefix(lines[0], "SERVICE") {
		t.Errorf("header = %q", lines[0])
	}
	// Ordered by IP, then registry order for ties: dnsmasq and the portal
	// both answer on the gateway .1 because both run on the VM itself,
	// and adminer is the lone container at .6.
	for i, want := range []string{"dnsmasq", "portal", "adminer"} {
		if !strings.HasPrefix(lines[i+2], want) {
			t.Errorf("row %d = %q, want it to start with %q", i, lines[i+2], want)
		}
	}
	// A container podman didn't report is not-created; a non-running one
	// is stopped. The distinction is what tells "never set up" from
	// "set up and down".
	// dnsmasq is systemd-backed, so its status comes from the injected
	// unit check rather than from podman ps — which reported nothing.
	if !strings.Contains(lines[2], "running") {
		t.Errorf("dnsmasq row = %q, want running (unit active)", lines[2])
	}
	if !strings.Contains(lines[3], "running") {
		t.Errorf("portal row = %q, want running (unit active)", lines[3])
	}
	if !strings.Contains(lines[4], "not-created") {
		t.Errorf("adminer row = %q, want not-created", lines[4])
	}
	if !strings.Contains(out, "https://150.mpd.test/") {
		t.Error("portal access hint should name the zone apex")
	}
}
