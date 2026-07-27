package control

import (
	"bufio"
	"os"
	"strings"
)

// EnvFile is the user-editable VM-wide override file. Read per request
// rather than at start-up: /var/lib/mpd/env is a directory mount, so an
// edit on the VM takes effect on the next command without restarting the
// daemon or touching any container.
const EnvFile = "/var/lib/mpd/env/mpd-vm.env"

// EnabledKey turns runtime-originated commands off.
//
// The switch exists because this feature widens what a runtime can reach:
// a compromised or confused agent inside one can create and delete
// projects, not just edit files in one tree. Anyone who does not want that
// trade needs a way to decline it that does not involve deleting sockets or
// editing units.
const EnabledKey = "MPD_RUNTIME_CONTROL"

// Enabled reports whether the daemon should serve requests, and if not, why.
//
// Default is on: the file normally has no opinion, and the feature is the
// reason the daemon is running at all. Only an explicit off/false/0/no
// disables it, so a typo'd value fails safe towards working rather than
// silently disabling mpd inside every runtime.
func Enabled(envPath string) (bool, string) {
	value, found := readEnvKey(envPath, EnabledKey)
	if !found {
		return true, ""
	}
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "off", "false", "0", "no":
		return false, "mpd from inside runtimes is disabled on this VM (" +
			EnabledKey + "=" + value + " in " + envPath + ").\n" +
			"Remove or change that line from a VM terminal and the next command " +
			"here works — no restart needed. Until then, use a VM terminal."
	}
	return true, ""
}

// readEnvKey reads one KEY=VALUE from an env-shaped file.
//
// A whitelist read of a single key, not a shell source: this file is
// user-editable, and nothing in it should be able to execute. Last
// occurrence wins, matching how the shell-side loader treats repeats.
func readEnvKey(path, key string) (string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer f.Close()

	value, found := "", false
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok || strings.TrimSpace(k) != key {
			continue
		}
		value, found = strings.Trim(strings.TrimSpace(v), `"'`), true
	}
	return value, found
}
