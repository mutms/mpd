package control

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"syscall"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/state"
)

// maxRequest caps a request; a valid one is a short argv and a path.
const maxRequest = 64 << 10

// expectedFDs is the required descriptor count: stdin, stdout, stderr.
// Any other count means the peer is not our client.
const expectedFDs = 3

// Serve listens on one socket per runtime and serves requests until ctx
// is cancelled.
//
// Each socket is bind-mounted into exactly one runtime, so the socket a
// connection arrived on is the caller's identity; the client never
// states who it is. SO_PEERCRED cannot do this job: every runtime runs
// the same UID-matched dev user. base is RunDir in production, a
// temporary directory in tests.
func Serve(ctx context.Context, out io.Writer, runtimes []string, base string,
	s state.Store, a assets.Tree) error {

	if err := os.MkdirAll(base, 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", base, err)
	}

	var wg sync.WaitGroup
	var listeners []*net.UnixListener
	for _, rt := range runtimes {
		listener, err := listen(base, rt)
		if err != nil {
			// Close what is already up, or a failed start leaves live
			// sockets with nothing serving them.
			for _, l := range listeners {
				l.Close()
			}
			return err
		}
		listeners = append(listeners, listener)
		fmt.Fprintf(out, "listening for the '%s' runtime on %s\n", rt, SocketPathIn(base, rt))

		wg.Add(1)
		go func(rt string, l *net.UnixListener) {
			defer wg.Done()
			acceptLoop(ctx, out, l, Guard{Runtime: rt, State: s, Assets: a})
		}(rt, listener)
	}

	<-ctx.Done()
	// Closing the listeners unblocks the accept loops.
	for _, l := range listeners {
		l.Close()
	}
	for _, rt := range runtimes {
		_ = os.Remove(SocketPathIn(base, rt))
	}
	wg.Wait()
	return nil
}

// listen binds a runtime's socket, replacing any socket left by a
// previous daemon. Unlinking first is required: bind fails with
// EADDRINUSE on an existing path even when nothing is listening. The
// directory is what is mounted, so the new inode appears inside running
// containers immediately.
func listen(base, rt string) (*net.UnixListener, error) {
	dir := SocketDirIn(base, rt)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("creating %s: %w", dir, err)
	}
	path := SocketPathIn(base, rt)
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return nil, fmt.Errorf("removing the stale socket %s: %w", path, err)
	}

	l, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return nil, fmt.Errorf("listening on %s: %w", path, err)
	}
	// 0660 lets the runtime's UID-matched dev user connect and nothing
	// else; the kernel enforces it across the container boundary.
	if err := os.Chmod(path, 0o660); err != nil {
		l.Close()
		return nil, fmt.Errorf("chmod %s: %w", path, err)
	}
	return l, nil
}

func acceptLoop(ctx context.Context, out io.Writer, l *net.UnixListener, g Guard) {
	defer l.Close()
	for {
		conn, err := l.AcceptUnix()
		if err != nil {
			if ctx.Err() != nil {
				return // shutting down
			}
			fmt.Fprintf(out, "accept on the '%s' socket failed: %v\n", g.Runtime, err)
			continue
		}
		// Serialised per runtime: concurrent requests from one runtime
		// would only race for the state lock the child takes anyway.
		handle(ctx, out, conn, g)
	}
}

// handle serves one request: receive, validate, run, reply.
func handle(ctx context.Context, out io.Writer, conn *net.UnixConn, g Guard) {
	defer conn.Close()

	req, files, err := receive(conn)
	// The received descriptors are this process's copies of the caller's
	// terminal; close them however this turns out.
	defer func() {
		for _, f := range files {
			if f != nil {
				f.Close()
			}
		}
	}()
	if err != nil {
		fmt.Fprintf(out, "'%s': %v\n", g.Runtime, err)
		reply(conn, response{Exit: 1, Error: err.Error()})
		return
	}

	decision, err := g.Check(req)
	if err != nil {
		// The refusal goes back over the socket, so the client owns the
		// presentation and the daemon's journal keeps a copy.
		fmt.Fprintf(out, "'%s' refused %v: %v\n", g.Runtime, req.Argv, err)
		reply(conn, response{Exit: 1, Error: err.Error()})
		return
	}

	code, runErr := run(ctx, decision, req, files)
	if runErr != nil {
		fmt.Fprintf(out, "'%s' running %v: %v\n", g.Runtime, decision.Argv, runErr)
		reply(conn, response{Exit: code, Error: runErr.Error()})
		return
	}
	reply(conn, response{Exit: code})
}

// run spawns mpd with the caller's descriptors as its own stdio.
//
// A child process, not an in-process call: every descendant inherits
// the caller's real descriptors, and a panic or os.Exit in a verb
// cannot take the daemon down. The binary is fixed and the argv has
// been through Guard.Check, so this never runs what the client named.
// The daemon must not hold the state lock here: the child takes it at
// its own entry point and would wait on its parent forever.
func run(ctx context.Context, d Decision, req Request, files []*os.File) (int, error) {
	cmd := exec.Cmd{
		Name: "mpd",
		Args: d.Argv,
		// Dir comes from the guard, not from the request: see Decision.Dir.
		Dir:    d.Dir,
		Stdin:  files[0],
		Stdout: files[1],
		Stderr: files[2],
	}
	if term := req.SafeTerm(); term != "" {
		cmd.Env = append(cmd.Env, "TERM="+term)
	}
	return exec.Run(ctx, cmd)
}

// receive reads one request and the three descriptors that came with it.
func receive(conn *net.UnixConn) (Request, []*os.File, error) {
	buf := make([]byte, maxRequest)
	oob := make([]byte, syscall.CmsgSpace(expectedFDs*4))

	n, oobn, _, _, err := conn.ReadMsgUnix(buf, oob)
	if err != nil {
		return Request{}, nil, fmt.Errorf("reading the request: %w", err)
	}

	files, err := parseFDs(oob[:oobn])
	if err != nil {
		return Request{}, files, err
	}

	var req Request
	if err := json.Unmarshal(trimNewline(buf[:n]), &req); err != nil {
		return Request{}, files, fmt.Errorf("unreadable request: %w", err)
	}
	return req, files, nil
}

// parseFDs turns the ancillary data into files, insisting on exactly three.
func parseFDs(oob []byte) ([]*os.File, error) {
	messages, err := syscall.ParseSocketControlMessage(oob)
	if err != nil {
		return nil, fmt.Errorf("reading the passed descriptors: %w", err)
	}
	var fds []int
	for _, m := range messages {
		got, err := syscall.ParseUnixRights(&m)
		if err != nil {
			// Not SCM_RIGHTS; a stray control message is not worth
			// failing over.
			continue
		}
		fds = append(fds, got...)
	}
	if len(fds) != expectedFDs {
		for _, fd := range fds {
			syscall.Close(fd)
		}
		return nil, fmt.Errorf("expected %d passed descriptors (stdin, stdout, stderr), got %d",
			expectedFDs, len(fds))
	}

	names := []string{"stdin", "stdout", "stderr"}
	files := make([]*os.File, len(fds))
	for i, fd := range fds {
		files[i] = os.NewFile(uintptr(fd), "client-"+names[i])
	}
	return files, nil
}

func reply(conn *net.UnixConn, resp response) {
	body, err := json.Marshal(resp)
	if err != nil {
		return
	}
	_, _ = conn.Write(append(body, '\n'))
}

// PruneSockets removes socket directories for runtimes that no longer
// exist, so a deleted runtime does not leave a live endpoint behind.
func PruneSockets(keep []string) error { return pruneSocketsIn(RunDir, keep) }

func pruneSocketsIn(base string, keep []string) error {
	wanted := map[string]bool{}
	for _, rt := range keep {
		wanted[rt] = true
	}
	entries, err := os.ReadDir(base)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	for _, e := range entries {
		if !e.IsDir() || wanted[e.Name()] {
			continue
		}
		if err := os.RemoveAll(filepath.Join(base, e.Name())); err != nil {
			return err
		}
	}
	return nil
}
