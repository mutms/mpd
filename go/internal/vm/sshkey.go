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
// Two separate reasons, both required:
//
//   - The keypair lets the VM SSH into its own runtimes. Without it the
//     developer would need `ssh -A` from the workstation for every hop,
//     which does not work from a terminal inside the VM's own desktop.
//   - ~/.ssh/authorized_keys is the SOURCE for what a runtime trusts:
//     runtime.AuthorizedPublicKeys reads it, adds the VM's own id_*.pub,
//     and installs the result into every runtime. A key missing here is a
//     key that reaches no runtime. Managed VMs get the file as a side
//     effect of cloud-init injecting the workstation key, but a sandbox
//     VM has no workstation side and may genuinely not have one — hence
//     creating it, empty if need be.
//
// The VM's own public key is deliberately NOT appended to it. It would
// reach the runtimes regardless (AuthorizedPublicKeys globs id_*.pub
// separately and dedupes the union), so the only thing it bought was the
// VM trusting its own key to log into itself, which nothing does. Leaving
// it out also keeps the two files visibly different: the VM's lists the
// workstation, the runtime's lists the workstation plus this VM, so the
// file says which box you are on.
//
// No passphrase: the VM is the trust boundary, and the key only
// authenticates VM→runtime hops.
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

// ensureAuthorizedKeys guarantees the file exists and is mode 600. It
// never writes a key into it: what a developer authorised for this VM is
// theirs, and mpd only reads it (as the source for what the runtimes
// trust). An entry left there by an earlier mpd is not removed either —
// pruning someone's authorized_keys is not a thing a setup command should
// do behind their back.
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
