package vm

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/mutms/mpd/go/internal/ui"
)

// Markers delimiting the block mpd owns in ~/.ssh/config. Everything
// between them is regenerated on every `mpd --vm-setup`; everything
// outside is the developer's and is preserved verbatim.
const (
	sshBlockStart = "# >>> mpd runtimes (managed by mpd --vm-setup) >>>"
	sshBlockEnd   = "# <<< mpd runtimes <<<"
)

// RuntimeHost is one runtime's SSH identity: the patterns `ssh` should
// accept for it, and the name it actually connects to.
//
// Name composition stays with the caller, which has net.Net — this
// package must not know that the runtime's FQDN is "runtime.<zone>".
type RuntimeHost struct {
	// Patterns are the `Host` patterns, in the order a developer is
	// likely to type them. Conventionally the VM-qualified alias
	// ("mpd-130-runtime"), the bare name ("runtime"), and the FQDN.
	Patterns []string
	// HostName is what ssh resolves and connects to — the FQDN dnsmasq
	// actually answers for.
	HostName string
}

// EnsureSSHConfig writes the runtime aliases into the dev user's
// ~/.ssh/config, so `ssh mpd-130-runtime` reaches runtime.130.mpd.test
// from a terminal on the VM.
//
// The aliases exist because only the FQDN is a dnsmasq record. Publishing
// short names in dnsmasq instead was rejected: this VM's resolver is
// authoritative for the whole `.test` tree (`local=/test/`), so a name
// it answers for is answered *finally* — and a bare `runtime` record would
// be a name with no zone, resolving inside every container on the VM and
// colliding with anything else that wanted it. An ssh alias is scoped to
// the one program that needs it, and to this user.
//
// Not the only route to the short name: ConfigureDNSResolver gives
// systemd-resolved this VM's zone as a search domain, which qualifies
// `runtime` for programs that never read ~/.ssh/config — an SSH client
// with a jump-host field and no config file, say. That is scoped to the
// VM's own resolution and still never becomes a dnsmasq answer.
//
// One self-contained block rather than a wildcard plus a
// shared options block: `ssh` has no captures in Host patterns, so the
// alias→FQDN mapping has to be enumerated anyway, and enumerating the
// options too removes the first-value-wins ordering subtlety entirely.
//
// The FQDN is listed as a pattern alongside the aliases so that the long
// form `mpd show` prints picks up the same User and host-key handling.
//
// Host keys are deliberately not verified: a runtime is a container that
// gets deleted and recreated freely, so its host key changes as a matter
// of routine, and the usual REMOTE HOST IDENTIFICATION HAS CHANGED wall
// would fire on ordinary use. The VM is the trust boundary (see
// EnsureSSHKey) and the target is an address on this VM's own private
// /24, so there is no meaningful man in the middle to catch. /dev/null
// as the known_hosts keeps the churn out of the developer's real file.
func EnsureSSHConfig(out io.Writer, user string, hosts []RuntimeHost) error {
	sshDir := filepath.Join(Home(), ".ssh")
	if err := os.MkdirAll(sshDir, 0o700); err != nil {
		return err
	}
	path := filepath.Join(sshDir, "config")

	existing, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("Failed to read %s: %w", path, err)
	}

	content := strings.TrimRight(stripBlock(string(existing), sshBlockStart, sshBlockEnd), "\n")
	block := renderSSHBlock(user, hosts)
	if content != "" {
		content += "\n\n"
	}
	content += block

	if string(existing) == content {
		ui.OK(out, "Runtime SSH aliases already current in ~/.ssh/config.")
		return nil
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		return fmt.Errorf("Failed to write %s: %w", path, err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		return err
	}

	if len(hosts) == 0 {
		ui.OK(out, "No runtimes in the assets tree — wrote an empty alias block.")
		return nil
	}
	var names []string
	for _, h := range hosts {
		if len(h.Patterns) > 0 {
			names = append(names, h.Patterns[0])
		}
	}
	ui.OK(out, "SSH aliases in ~/.ssh/config: %s", strings.Join(names, ", "))
	return nil
}

// stripBlock removes a previously written managed block, leaving the rest
// of the file untouched. Shared by every dotfile mpd co-owns with the
// developer, hence the markers as parameters.
//
// An unterminated block — a start marker with no end, from a truncated
// write or a hand-edit — takes the remainder of the file with it. That is
// the safe reading: the alternative is treating the developer's own
// trailing content as part of the block and duplicating a start marker
// above it, which compounds on every run.
func stripBlock(body, start, end string) string {
	var kept []string
	inBlock := false
	for _, line := range strings.Split(body, "\n") {
		switch {
		case strings.TrimSpace(line) == start:
			inBlock = true
		case inBlock && strings.TrimSpace(line) == end:
			inBlock = false
		case !inBlock:
			kept = append(kept, line)
		}
	}
	return strings.Join(kept, "\n")
}

func renderSSHBlock(user string, hosts []RuntimeHost) string {
	var b strings.Builder
	b.WriteString(sshBlockStart + "\n")
	b.WriteString("# Regenerated by `mpd --vm-setup`. Edits inside this block are lost;\n")
	b.WriteString("# put your own entries outside it.\n")
	for _, h := range hosts {
		if h.HostName == "" || len(h.Patterns) == 0 {
			continue
		}
		b.WriteString("\nHost " + strings.Join(h.Patterns, " ") + "\n")
		b.WriteString("    HostName " + h.HostName + "\n")
		if user != "" {
			b.WriteString("    User " + user + "\n")
		}
		// See the EnsureSSHConfig comment on host keys.
		b.WriteString("    StrictHostKeyChecking no\n")
		b.WriteString("    UserKnownHostsFile /dev/null\n")
		b.WriteString("    LogLevel ERROR\n")
	}
	b.WriteString(sshBlockEnd + "\n")
	return b.String()
}
