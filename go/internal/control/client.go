package control

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"syscall"
)

// response is what the daemon sends back: one JSON line, then EOF.
type response struct {
	// Exit is the child's exit status, passed through untouched.
	Exit int `json:"exit"`
	// Error is set when the request was refused before anything ran. The
	// client prints it; the daemon has written nothing to the caller's
	// terminal in that case.
	Error string `json:"error,omitempty"`
}

// maxResponse caps what the client will read back. The response is a short
// JSON object, so anything larger means the socket is not what we think.
const maxResponse = 64 << 10

// Forward sends this process's command line to the VM's control daemon and
// returns the exit code of the mpd that ran there.
//
// # What crosses the socket
//
// The argv and the working directory, as one JSON line — plus this
// process's real stdin, stdout and stderr file descriptors, passed as
// SCM_RIGHTS ancillary data.
//
// Sending the descriptors rather than proxying bytes is what makes a
// forwarded command indistinguishable from a local one. The mpd that runs
// on the VM writes to *this* terminal: a tty stays a tty, so width
// detection and colour work, progress output is unbuffered, and an
// interactive confirmation prompt reads the keystrokes of the person who
// typed the command. None of that survives a relay through the daemon.
//
// The daemon closes its copies when the child exits, so nothing is left
// holding this terminal open.
func Forward(argv []string) (int, error) {
	rt, ok := RuntimeName()
	if !ok {
		return 1, fmt.Errorf("not inside an mpd runtime (%s is missing)", RuntimeFile)
	}
	return ForwardTo(SocketPath(rt), argv)
}

// ForwardTo is Forward against an explicit socket path, so the transport
// can be tested without a real runtime.
func ForwardTo(path string, argv []string) (int, error) {
	return forwardWithFiles(path, argv, os.Stdin, os.Stdout, os.Stderr)
}

// forwardWithFiles is ForwardTo with the three descriptors named
// explicitly. Tests pass temporary files so they can assert on what the
// daemon side wrote through them.
func forwardWithFiles(path string, argv []string, stdin, stdout, stderr *os.File) (int, error) {
	cwd, err := os.Getwd()
	if err != nil {
		return 1, fmt.Errorf("cannot read the working directory: %w", err)
	}

	conn, err := net.Dial("unix", path)
	if err != nil {
		return 1, fmt.Errorf(
			"cannot reach mpd on the VM at %s: %w\n"+
				"The control daemon may not be running. From a VM terminal: "+
				"systemctl --user status mpd-control", path, err)
	}
	defer conn.Close()

	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		return 1, fmt.Errorf("internal error: %s is not a Unix socket", path)
	}

	payload, err := json.Marshal(Request{Argv: argv, Cwd: cwd, Term: os.Getenv("TERM")})
	if err != nil {
		return 1, err
	}
	payload = append(payload, '\n')

	// One sendmsg carrying both the request and the descriptors, so the
	// daemon can never see a request without its FDs or vice versa.
	rights := syscall.UnixRights(
		int(stdin.Fd()), int(stdout.Fd()), int(stderr.Fd()))
	if _, _, err := unixConn.WriteMsgUnix(payload, rights, nil); err != nil {
		return 1, fmt.Errorf("sending the command to the VM failed: %w", err)
	}

	// The daemon replies only once its child has finished, so this read is
	// also how the client waits.
	line, err := bufio.NewReaderSize(unixConn, maxResponse).ReadBytes('\n')
	if err != nil && len(line) == 0 {
		return 1, fmt.Errorf("the VM closed the connection without replying: %w", err)
	}

	var resp response
	if err := json.Unmarshal(trimNewline(line), &resp); err != nil {
		return 1, fmt.Errorf("unreadable reply from the VM: %w", err)
	}
	if resp.Error != "" {
		return resp.Exit, fmt.Errorf("%s", resp.Error)
	}
	return resp.Exit, nil
}

func trimNewline(b []byte) []byte {
	for len(b) > 0 && (b[len(b)-1] == '\n' || b[len(b)-1] == '\r') {
		b = b[:len(b)-1]
	}
	return b
}
