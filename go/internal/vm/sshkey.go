package vm

import (
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/mutms/mpd/go/internal/ui"
)

// EnsureSSHDir makes sure ~/.ssh and ~/.ssh/authorized_keys exist.
//
// mpd deliberately generates no keypair here: nothing reads one, and a
// passphrase-less key in a home that project code and AI agents share is
// a credential inside the blast radius. Wherever such a key is
// authorized, one bad postinstall pivots there. See docs/security.md.
// A developer who wants one runs `ssh-keygen`.
func EnsureSSHDir(out io.Writer) error {
	sshDir := filepath.Join(Home(), ".ssh")
	if err := os.MkdirAll(sshDir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(sshDir, 0o700); err != nil {
		return err
	}
	return ensureAuthorizedKeys(out, sshDir)
}

// ensureAuthorizedKeys guarantees the file exists with mode 600. It
// never writes or prunes keys: the file is the developer's, and mpd only
// reads it.
func ensureAuthorizedKeys(out io.Writer, sshDir string) error {
	authPath := filepath.Join(sshDir, "authorized_keys")
	if _, err := os.Stat(authPath); err != nil {
		if err := os.WriteFile(authPath, nil, 0o600); err != nil {
			return fmt.Errorf("Failed to create %s.", authPath)
		}
		ui.OK(out, "Created an empty ~/.ssh/authorized_keys.")
	}
	if err := os.Chmod(authPath, 0o600); err != nil {
		return err
	}
	return nil
}
