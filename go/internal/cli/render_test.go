package cli

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/state"
)

// Column padding never truncates, including the over-width case: an
// over-width name keeps all its characters and still gets two trailing
// spaces, so a long name pushes the row instead of losing characters.
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
// codes would leak into the rendered text.
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
	// Extra services only: nothing installed means every row reads
	// "not installed" with the enable command as the access hint.
	ps := `[]`
	var buf bytes.Buffer
	ListServices(context.Background(), &buf, testNet(t, 150), stubPodman(ps), state.NewAt(t.TempDir()))
	out := buf.String()

	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if len(lines) != 5 { // header + rule + 3 services
		t.Fatalf("got %d lines, want 5:\n%s", len(lines), out)
	}
	if !strings.HasPrefix(lines[0], "SERVICE") {
		t.Errorf("header = %q", lines[0])
	}
	// Registry order: mailpit, adminer, seleniumv1 — infra (dnsmasq,
	// portal) deliberately absent, that is `mpd list infra`.
	for i, want := range []string{"mailpit", "adminer", "seleniumv1"} {
		if !strings.HasPrefix(lines[i+2], want) {
			t.Errorf("row %d = %q, want it to start with %q", i, lines[i+2], want)
		}
	}
	for _, forbidden := range []string{"dnsmasq", "portal"} {
		if strings.Contains(out, forbidden) {
			t.Errorf("infra %q must not appear under services:\n%s", forbidden, out)
		}
	}
	if !strings.Contains(lines[2], "not installed") {
		t.Errorf("mailpit row = %q, want not installed", lines[2])
	}
	if !strings.Contains(lines[2], "--service-enable=mailpit") {
		t.Errorf("mailpit row = %q, want the enable hint", lines[2])
	}
}

func TestListInfra(t *testing.T) {
	var buf bytes.Buffer
	unitActive := func(context.Context, string, bool) bool { return true }
	ListInfra(context.Background(), &buf, testNet(t, 150), unitActive)
	out := buf.String()

	for _, want := range []string{"dnsmasq", "portal", "https://150.mpd.test/", "running"} {
		if !strings.Contains(out, want) {
			t.Errorf("infra listing should contain %q:\n%s", want, out)
		}
	}
}
