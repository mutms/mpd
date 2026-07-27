package control

import (
	"os"
	"path/filepath"
	"strings"
)

// RunDir holds one directory per runtime, each containing that runtime's
// control socket. Owned by the dev user, like everything else mpd writes.
//
// Under /var/lib/mpd rather than the FHS-conventional /run for one
// concrete reason: this directory is a bind-mount source for a long-lived
// container. /run is a tmpfs and is emptied on reboot, which would leave
// every existing runtime pointing at a mount source that no longer exists.
// /var/lib/mpd survives, so the mount stays valid for the life of the
// container and the daemon simply rebinds its socket on start.
//
// It is NOT one of the four documented state directories and holds no
// state: only sockets, recreated from scratch whenever the daemon starts.
const RunDir = "/var/lib/mpd/run"

// SocketName is the socket inside a runtime's directory.
const SocketName = "control.sock"

// RuntimeFile is written into every runtime container by its bootstrap and
// contains just the runtime's name. It is how an mpd process knows it is
// running inside a runtime rather than on the VM.
const RuntimeFile = "/etc/mpd/runtime"

// SocketDir is the directory bind-mounted into runtime rt.
//
// The directory is what gets mounted, not the socket file: mounting the
// file would pin one inode, and the daemon unlinks and rebinds its socket
// every time it starts. With a directory mount a rebound socket is
// immediately visible inside an already-running container — measured, not
// assumed.
func SocketDir(rt string) string { return SocketDirIn(RunDir, rt) }

// SocketDirIn is SocketDir under an arbitrary base, so the daemon and its
// tests can be pointed at a temporary directory instead of the real one.
func SocketDirIn(base, rt string) string { return filepath.Join(base, rt) }

// SocketPathIn is SocketPath under an arbitrary base.
func SocketPathIn(base, rt string) string { return filepath.Join(SocketDirIn(base, rt), SocketName) }

// SocketPath is the socket a runtime's client connects to, and the one the
// daemon listens on for that runtime.
//
// The path carries the caller's identity: this socket is mounted into
// runtime rt and nowhere else, so a connection arriving here proves the
// caller is rt without the client asserting anything.
func SocketPath(rt string) string { return SocketPathIn(RunDir, rt) }

// RuntimeName reports the runtime this process is running inside, and
// whether it is inside one at all.
//
// Presence of /etc/mpd/runtime is the test. On the VM the file does not
// exist, so the same binary takes the normal control-plane path; inside a
// runtime it names the runtime, which is exactly what the client needs to
// find its socket.
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

// validRuntimeName reports whether name is usable as a single path element.
//
// The name becomes part of a socket path, so anything that could traverse
// out of RunDir is refused. The file it comes from is written by mpd's own
// bootstrap and is not attacker-controlled today, but a value that turns
// into a filesystem path is checked where it is read, not where it is
// trusted to have come from.
func validRuntimeName(name string) bool {
	if name == "" || name == "." || name == ".." {
		return false
	}
	return name == filepath.Base(name)
}
