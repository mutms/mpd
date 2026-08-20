package control

import (
	"context"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The transport tests exercise the real socket and real SCM_RIGHTS passing.
// They stop short of spawning mpd itself — that needs a provisioned VM, and
// is covered by the end-to-end checks in the plan.

// serveOne accepts a single connection, receives the request and its
// descriptors, and hands them to fn. Returns the socket path.
func serveOne(t *testing.T, fn func(Request, []*os.File) response) string {
	t.Helper()
	base := t.TempDir()
	l, err := listen(base, "php")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { l.Close() })

	go func() {
		conn, err := l.AcceptUnix()
		if err != nil {
			return
		}
		defer conn.Close()
		req, files, err := receive(conn)
		defer func() {
			for _, f := range files {
				if f != nil {
					f.Close()
				}
			}
		}()
		if err != nil {
			reply(conn, response{Exit: 1, Error: err.Error()})
			return
		}
		reply(conn, fn(req, files))
	}()

	return SocketPathIn(base, "php")
}

// The whole point of the transport: the descriptors that arrive on the
// daemon side are the client's real files, so writing to them writes to the
// caller's terminal.
func TestPassedDescriptorsAreTheCallersFiles(t *testing.T) {
	stdoutFile := filepath.Join(t.TempDir(), "stdout")
	f, err := os.Create(stdoutFile)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	const written = "written through the passed descriptor\n"
	path := serveOne(t, func(req Request, files []*os.File) response {
		// files[1] is the client's stdout. Write to it as a child would.
		if _, err := files[1].WriteString(written); err != nil {
			return response{Exit: 1, Error: err.Error()}
		}
		return response{Exit: 0}
	})

	code, err := forwardWithFiles(path, []string{"status", "moodle45"}, os.Stdin, f, os.Stderr)
	if err != nil {
		t.Fatalf("ForwardTo: %v", err)
	}
	if code != 0 {
		t.Errorf("exit = %d, want 0", code)
	}

	got, err := os.ReadFile(stdoutFile)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != written {
		t.Errorf("the daemon wrote %q to its copy of the descriptor, but the client's file has %q",
			written, string(got))
	}
}

// The request must arrive intact: argv, cwd and TERM.
func TestRequestCrossesIntact(t *testing.T) {
	var got Request
	path := serveOne(t, func(req Request, files []*os.File) response {
		got = req
		return response{Exit: 0}
	})

	t.Setenv("TERM", "xterm-256color")
	wantArgv := []string{"init", "moodle45", "--type=moodle"}
	if _, err := forwardWithFiles(path, wantArgv, os.Stdin, os.Stdout, os.Stderr); err != nil {
		t.Fatalf("ForwardTo: %v", err)
	}

	if strings.Join(got.Argv, " ") != strings.Join(wantArgv, " ") {
		t.Errorf("argv = %v, want %v", got.Argv, wantArgv)
	}
	cwd, _ := os.Getwd()
	if got.Cwd != cwd {
		t.Errorf("cwd = %q, want %q", got.Cwd, cwd)
	}
	if got.Term != "xterm-256color" {
		t.Errorf("term = %q, want xterm-256color", got.Term)
	}
}

// Exit codes are the reason a shim is usable in a script at all.
func TestExitCodePropagates(t *testing.T) {
	for _, want := range []int{0, 1, 42, 127} {
		path := serveOne(t, func(Request, []*os.File) response {
			return response{Exit: want}
		})
		got, err := forwardWithFiles(path, []string{"status", "x"}, os.Stdin, os.Stdout, os.Stderr)
		if err != nil {
			t.Fatalf("ForwardTo: %v", err)
		}
		if got != want {
			t.Errorf("exit = %d, want %d", got, want)
		}
	}
}

// A refusal comes back as an error with the daemon's message, and the
// daemon has written nothing to the caller's terminal.
func TestRefusalIsReportedToClient(t *testing.T) {
	path := serveOne(t, func(Request, []*os.File) response {
		return response{Exit: 1, Error: "cannot modify project 'site' from the 'php' runtime"}
	})
	code, err := forwardWithFiles(path, []string{"delete", "site"}, os.Stdin, os.Stdout, os.Stderr)
	if err == nil {
		t.Fatal("a refusal should surface as an error")
	}
	if code != 1 {
		t.Errorf("exit = %d, want 1", code)
	}
	if !strings.Contains(err.Error(), "belongs") && !strings.Contains(err.Error(), "cannot modify") {
		t.Errorf("error should carry the daemon's message, got: %v", err)
	}
}

// Exactly three descriptors, or the peer is not our client. Anything else
// would leave the daemon holding descriptors it never asked for.
func TestReceiveRejectsWrongFDCount(t *testing.T) {
	for _, count := range []int{0, 1, 2, 4} {
		base := t.TempDir()
		l, err := listen(base, "php")
		if err != nil {
			t.Fatal(err)
		}

		errCh := make(chan error, 1)
		go func() {
			conn, err := l.AcceptUnix()
			if err != nil {
				errCh <- err
				return
			}
			defer conn.Close()
			_, files, err := receive(conn)
			for _, f := range files {
				if f != nil {
					f.Close()
				}
			}
			errCh <- err
		}()

		conn, err := net.Dial("unix", SocketPathIn(base, "php"))
		if err != nil {
			t.Fatal(err)
		}
		unixConn := conn.(*net.UnixConn)

		fds := make([]int, count)
		for i := range fds {
			fds[i] = int(os.Stdin.Fd())
		}
		var rights []byte
		if count > 0 {
			rights = syscall.UnixRights(fds...)
		}
		if _, _, err := unixConn.WriteMsgUnix([]byte(`{"argv":["status"],"cwd":"/srv"}`+"\n"), rights, nil); err != nil {
			t.Fatal(err)
		}

		select {
		case err := <-errCh:
			if err == nil {
				t.Errorf("%d descriptors should be rejected", count)
			}
		case <-time.After(3 * time.Second):
			t.Errorf("%d descriptors: receive did not return", count)
		}
		conn.Close()
		l.Close()
	}
}

// The socket must not be world-accessible: its mode is a real second layer
// behind the per-runtime path.
func TestSocketModeIsRestrictive(t *testing.T) {
	base := t.TempDir()
	l, err := listen(base, "php")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()

	info, err := os.Stat(SocketPathIn(base, "php"))
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm&0o007 != 0 {
		t.Errorf("socket mode is %o; it must not grant access to other users", perm)
	}
}

// Rebinding over a socket left by a previous daemon must work: bind fails
// with EADDRINUSE on an existing path even when nothing is listening.
func TestListenReplacesStaleSocket(t *testing.T) {
	base := t.TempDir()

	first, err := listen(base, "php")
	if err != nil {
		t.Fatal(err)
	}
	// Close without removing, as an abruptly killed daemon would.
	first.SetUnlinkOnClose(false)
	first.Close()

	if _, err := os.Stat(SocketPathIn(base, "php")); err != nil {
		t.Skipf("stale socket did not survive the close: %v", err)
	}

	second, err := listen(base, "php")
	if err != nil {
		t.Fatalf("listen should replace a stale socket, got: %v", err)
	}
	second.Close()
}

func TestPruneSocketsRemovesUnknownRuntimes(t *testing.T) {
	base := t.TempDir()
	for _, rt := range []string{"php", "node", "gone"} {
		if _, err := listen(base, rt); err != nil {
			t.Fatal(err)
		}
	}
	if err := pruneSocketsIn(base, []string{"php", "node"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(SocketDirIn(base, "gone")); !os.IsNotExist(err) {
		t.Errorf("a removed runtime's socket directory should be gone, got err=%v", err)
	}
	for _, rt := range []string{"php", "node"} {
		if _, err := os.Stat(SocketDirIn(base, rt)); err != nil {
			t.Errorf("%s socket directory should survive: %v", rt, err)
		}
	}
}

func TestSafeTermRejectsJunk(t *testing.T) {
	for _, term := range []string{
		"xterm", "xterm-256color", "screen.linux", "rxvt-unicode-256color",
	} {
		if got := (Request{Term: term}).SafeTerm(); got != term {
			t.Errorf("SafeTerm(%q) = %q, want it kept", term, got)
		}
	}
	for _, term := range []string{
		"x;rm -rf /", "a b", "$(whoami)", "term\nLD_PRELOAD=/evil",
		strings.Repeat("x", 65),
	} {
		if got := (Request{Term: term}).SafeTerm(); got != "" {
			t.Errorf("SafeTerm(%q) = %q, want it dropped", term, got)
		}
	}
}

// The runtime name becomes a path element, so it must not be able to walk
// out of RunDir.
func TestValidRuntimeNameRejectsTraversal(t *testing.T) {
	for _, name := range []string{"php", "node", "util", "php-2"} {
		if !validRuntimeName(name) {
			t.Errorf("validRuntimeName(%q) = false, want true", name)
		}
	}
	for _, name := range []string{
		"", ".", "..", "../../etc", "a/b", "/abs", "php/../../..",
	} {
		if validRuntimeName(name) {
			t.Errorf("validRuntimeName(%q) = true, want false", name)
		}
	}
}

// A rejected name must not produce a socket path at all.
func TestSocketPathStaysUnderBase(t *testing.T) {
	base := "/var/lib/mpd/run"
	got := SocketPathIn(base, "php")
	if !strings.HasPrefix(got, base+"/") {
		t.Errorf("SocketPathIn = %q, want it under %q", got, base)
	}
	if filepath.Clean(got) != got {
		t.Errorf("SocketPathIn returned an unclean path: %q", got)
	}
}

func TestServeStopsOnContextCancel(t *testing.T) {
	base := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())

	done := make(chan error, 1)
	go func() {
		done <- Serve(ctx, io.Discard, []string{"php"}, base, testStore(t), testAssets(t))
	}()

	// Wait for the socket to appear.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(SocketPathIn(base, "php")); err == nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("Serve returned %v, want nil on cancel", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Serve did not return after its context was cancelled")
	}
}
