package vm

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/ui"
)

// EnsureSSHKey gives the VM its own keypair and makes sure
// ~/.ssh/authorized_keys exists.
//
// The keypair authenticates VM→runtime SSH without agent forwarding.
// authorized_keys is the source for what a runtime trusts
// (runtime.AuthorizedPublicKeys reads it); a sandbox VM may have none,
// so it is created empty. The VM's own public key is deliberately not
// appended: it reaches the runtimes via the id_*.pub glob anyway.
// No passphrase: the VM is the trust boundary.
func EnsureSSHKey(ctx context.Context, out io.Writer) error {
	sshDir := filepath.Join(Home(), ".ssh")
	if err := os.MkdirAll(sshDir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(sshDir, 0o700); err != nil {
		return err
	}

	keyPath := filepath.Join(sshDir, "id_ed25519")

	if hasPublicKey(sshDir) {
		ui.OK(out, "VM-local key already present in ~/.ssh/.")
	} else {
		host, _ := os.Hostname()
		if code, err := exec.Run(ctx, exec.Cmd{
			Name: "ssh-keygen",
			Args: []string{"-t", "ed25519", "-N", "", "-f", keyPath, "-C", "mpd VM " + host, "-q"},
		}); err != nil || code != 0 {
			return fmt.Errorf("Failed to generate ~/.ssh/id_ed25519. " +
				"Run `ssh-keygen -t ed25519` manually and re-run mpd --vm-setup.")
		}
		ui.OK(out, "Generated VM-local key at ~/.ssh/id_ed25519 "+
			"(no passphrase, used for VM→runtime SSH).")
	}

	return ensureAuthorizedKeys(out, sshDir)
}

func hasPublicKey(sshDir string) bool {
	entries, err := os.ReadDir(sshDir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "id_") && strings.HasSuffix(e.Name(), ".pub") {
			return true
		}
	}
	return false
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
