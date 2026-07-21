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
// ~/.ssh/authorized_keys exists with that key in it.
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
//     VM has no workstation side and may genuinely not have one.
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
	pubPath := keyPath + ".pub"

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

	return ensureAuthorizedKeys(out, sshDir, pubPath)
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

func ensureAuthorizedKeys(out io.Writer, sshDir, pubPath string) error {
	authPath := filepath.Join(sshDir, "authorized_keys")
	existing, err := os.ReadFile(authPath)
	if err != nil {
		if err := os.WriteFile(authPath, nil, 0o600); err != nil {
			return fmt.Errorf("Failed to create %s.", authPath)
		}
		existing = nil
	}
	if err := os.Chmod(authPath, 0o600); err != nil {
		return err
	}

	pub, err := os.ReadFile(pubPath)
	if err != nil {
		// No VM pubkey — should not happen after ssh-keygen. Nothing to
		// append, so leave authorized_keys as it stands.
		return nil
	}
	line := strings.TrimSpace(string(pub))

	// Match on the base64 blob, the middle field, so a re-keyed VM with
	// a different comment does not append a duplicate line.
	fields := strings.Fields(line)
	if len(fields) < 2 {
		return nil
	}
	if strings.Contains(string(existing), fields[1]) {
		ui.OK(out, "VM pubkey already in ~/.ssh/authorized_keys.")
		return nil
	}

	body := string(existing)
	if body != "" && !strings.HasSuffix(body, "\n") {
		body += "\n"
	}
	body += line + "\n"
	if err := os.WriteFile(authPath, []byte(body), 0o600); err != nil {
		return err
	}
	ui.OK(out, "Appended VM pubkey to ~/.ssh/authorized_keys.")
	return nil
}
