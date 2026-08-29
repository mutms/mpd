package control

import (
	"os"
	"path/filepath"
	"strings"
)

// RunDir holds one directory per runtime, each containing that
// runtime's control socket. Not under /run: the directory is a
// bind-mount source for a long-lived container, and /run is a tmpfs
// emptied on reboot. Holds no state — only sockets, recreated whenever
// the daemon starts.
const RunDir = "/var/lib/mpd/run"

// SocketName is the socket inside a runtime's directory.
const SocketName = "control.sock"

// RuntimeFile names the calling runtime and exists only inside runtime
// containers; its presence is how mpd knows it is not on the VM.
const RuntimeFile = "/etc/mpd/runtime"

// SocketDir is the directory bind-mounted into runtime rt. The
// directory is mounted, not the socket file: the daemon unlinks and
// rebinds its socket on every start, and a file mount would pin the old
// inode.
func SocketDir(rt string) string { return SocketDirIn(RunDir, rt) }

// SocketDirIn is SocketDir under an arbitrary base, for tests.
func SocketDirIn(base, rt string) string { return filepath.Join(base, rt) }

// SocketPathIn is SocketPath under an arbitrary base.
func SocketPathIn(base, rt string) string { return filepath.Join(SocketDirIn(base, rt), SocketName) }

// SocketPath is the socket a runtime's client connects to. The path
// carries the caller's identity: it is mounted into runtime rt and
// nowhere else, so a connection here proves the caller is rt.
func SocketPath(rt string) string { return SocketPathIn(RunDir, rt) }

// RuntimeName reports the runtime this process is running inside, and
// whether it is inside one at all.
func RuntimeName() (string, bool) {
	body, err := os.ReadFile(RuntimeFile)
	if err != nil {
		return "", false
	}
	name := strings.TrimSpace(string(body))
	if !validRuntimeName(name) {
		return "", false
	}
	return name, true
}

// validRuntimeName reports whether name is usable as a single path
// element. The name becomes part of a socket path, so anything that
// could traverse out of RunDir is refused where it is read.
func validRuntimeName(name string) bool {
	if name == "" || name == "." || name == ".." {
		return false
	}
	return name == filepath.Base(name)
}
