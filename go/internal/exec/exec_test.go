package exec

import (
	"context"
	"strings"
	"testing"
)

func TestCaptureStdout(t *testing.T) {
	res, err := Capture(context.Background(), Cmd{
		Name: "bash", Args: []string{"-c", "echo hello world"},
	})
	if err != nil {
		t.Fatalf("unexpected start error: %v", err)
	}
	if res.Code != 0 {
		t.Fatalf("code = %d, want 0", res.Code)
	}
	if res.Stdout != "hello world" {
		t.Fatalf("stdout = %q, want %q", res.Stdout, "hello world")
	}
}

func TestCaptureNonZeroWithStderr(t *testing.T) {
	res, err := Capture(context.Background(), Cmd{
		Name: "bash", Args: []string{"-c", "echo oops >&2; exit 3"},
	})
	if err != nil {
		t.Fatalf("unexpected start error: %v", err)
	}
	if res.Code != 3 {
		t.Fatalf("code = %d, want 3", res.Code)
	}
	if !res.Failed() {
		t.Fatal("Failed() = false, want true")
	}
	if res.Stderr != "oops" {
		t.Fatalf("stderr = %q, want %q", res.Stderr, "oops")
	}
	if e := res.Err(); e == nil || !strings.Contains(e.Error(), "oops") {
		t.Fatalf("Err() = %v, want error containing stderr", e)
	}
}

func TestExitZeroHasNilErr(t *testing.T) {
	res, err := Capture(context.Background(), Cmd{Name: "bash", Args: []string{"-c", "true"}})
	if err != nil {
		t.Fatalf("unexpected start error: %v", err)
	}
	if res.Err() != nil {
		t.Fatalf("Err() = %v, want nil for exit 0", res.Err())
	}
}

// The allow-list is the reason this package exists: an arbitrary binary
// must not be runnable even when it is present on PATH.
func TestNotAllowListedIsRefused(t *testing.T) {
	res, err := Capture(context.Background(), Cmd{Name: "echo"})
	if err == nil {
		t.Fatal("err = nil, want refusal for a non-allow-listed command")
	}
	if res.Code != ExitNotPermitted {
		t.Fatalf("code = %d, want %d", res.Code, ExitNotPermitted)
	}
	if !strings.Contains(err.Error(), "allow-listed") {
		t.Fatalf("err = %v, want it to name the allow-list", err)
	}
}

func TestPathIsAbsolute(t *testing.T) {
	for _, name := range Names() {
		p, ok := Path(name)
		if !ok {
			t.Fatalf("Path(%q) not found although Names() listed it", name)
		}
		if !strings.HasPrefix(p, "/") {
			t.Errorf("Path(%q) = %q, want an absolute path", name, p)
		}
	}
}

func TestAvailableRejectsUnknown(t *testing.T) {
	if Available("definitely-not-a-real-binary") {
		t.Fatal("Available() = true for an unknown command")
	}
	// bash is allow-listed and present on any Debian VM mpd supports.
	if !Available("bash") {
		t.Fatal("Available(\"bash\") = false, want true")
	}
}

func TestStdinIsPassedThrough(t *testing.T) {
	res, err := Capture(context.Background(), Cmd{
		Name:  "bash",
		Args:  []string{"-c", "cat"},
		Stdin: strings.NewReader("piped input"),
	})
	if err != nil {
		t.Fatalf("unexpected start error: %v", err)
	}
	if res.Stdout != "piped input" {
		t.Fatalf("stdout = %q, want %q", res.Stdout, "piped input")
	}
}

func TestEnvIsAppended(t *testing.T) {
	res, err := Capture(context.Background(), Cmd{
		Name: "bash",
		Args: []string{"-c", "echo $MPD_TEST_VAR"},
		Env:  []string{"MPD_TEST_VAR=set-by-test"},
	})
	if err != nil {
		t.Fatalf("unexpected start error: %v", err)
	}
	if res.Stdout != "set-by-test" {
		t.Fatalf("stdout = %q, want %q", res.Stdout, "set-by-test")
	}
}
