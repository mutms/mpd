package control

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"syscall"
)

// response is the daemon's reply: one JSON line, then EOF.
type response struct {
	Exit int `json:"exit"`
	// Error is set when the request was refused before anything ran.
	Error string `json:"error,omitempty"`
}

// maxResponse caps the reply; a valid response is a short JSON object.
const maxResponse = 64 << 10

// Forward sends this process's command line to the VM's control daemon
// and returns the exit code of the mpd that ran there.
//
// The request carries argv, cwd and TERM, plus the caller's real stdin,
// stdout and stderr as SCM_RIGHTS descriptors. Passing descriptors keeps
// the child on the caller's terminal, so tty detection, colour and
// interactive prompts work.
func Forward(argv []string) (int, error) {
	rt, ok := RuntimeName()
	if !ok {
		return 1, fmt.Errorf("not inside an mpd runtime (%s is missing)", RuntimeFile)
	}
	return ForwardTo(SocketPath(rt), argv)
}

// ForwardTo is Forward against an explicit socket path, for tests.
func ForwardTo(path string, argv []string) (int, error) {
	return forwardWithFiles(path, argv, os.Stdin, os.Stdout, os.Stderr)
}

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

	// One sendmsg carries both the request and the descriptors, so the
	// daemon can never see one without the other.
	rights := syscall.UnixRights(
		int(stdin.Fd()), int(stdout.Fd()), int(stderr.Fd()))
	if _, _, err := unixConn.WriteMsgUnix(payload, rights, nil); err != nil {
		return 1, fmt.Errorf("sending the command to the VM failed: %w", err)
	}

	// The daemon replies only after its child exits, so this read is also
	// how the client waits.
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
