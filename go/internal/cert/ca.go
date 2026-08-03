package cert

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/mutms/mpd/go/internal/exec"
)

// CAConfig is the openssl config the local CA is generated from.
//
// KEEP IN SYNC with the two host-side twins that may generate the same
// CA before a VM exists: the mpd-virt repo's Go `ca` package
// (go/internal/ca), and the `generate_mpd_ca` function in
// setup/linux/lib/common.sh. All three must produce a certificate with an
// identical DN, v3_ca extensions and name constraints, because a VM
// reuses whichever one it finds.
//
// The name constraint is what makes this CA safe to trust on the
// developer's own workstation: `permitted;DNS.0 = .mpd.test` means a
// certificate this CA signs is rejected for every name outside the test
// domain, so a stolen CA key cannot be used to impersonate a real site.
// The leading dot permits arbitrary depth, which is why one CA covers
// every VM's per-VM zone.
const CAConfig = `[ req ]
distinguished_name = req_dn
x509_extensions    = v3_ca
prompt             = no

[ req_dn ]
O  = mpd.test local development CA
CN = mpd.test local development CA

[ v3_ca ]
basicConstraints       = critical, CA:TRUE, pathlen:0
subjectKeyIdentifier   = hash
keyUsage               = critical, keyCertSign, cRLSign
nameConstraints        = critical, @name_constraints

[ name_constraints ]
permitted;DNS.0        = .mpd.test
permitted;DNS.1        = mpd.test`

// CADaysStr is the CA's validity. Long, unlike the leaf certs: rotating
// the CA means re-trusting it in four places on the workstation, so it
// should outlive the VM rather than the other way round.
const CADaysStr = "3650"

// GenerateCA creates the local CA key and certificate.
func GenerateCA(ctx context.Context, keyPath, certPath string) error {
	if err := os.MkdirAll(TempDir, 0o700); err != nil {
		return err
	}
	confPath := filepath.Join(TempDir, "mpd-ca.conf")
	if err := os.WriteFile(confPath, []byte(CAConfig+"\n"), 0o600); err != nil {
		return err
	}
	defer os.Remove(confPath)

	steps := [][]string{
		{"genrsa", "-out", keyPath, "4096"},
		{"req", "-new", "-x509", "-key", keyPath, "-out", certPath,
			"-days", CADaysStr, "-config", confPath},
	}
	for _, args := range steps {
		res, err := exec.Capture(ctx, exec.Cmd{Name: "openssl", Args: args})
		if err != nil {
			return fmt.Errorf("openssl %s: %w", args[0], err)
		}
		if res.Code != 0 {
			return fmt.Errorf("Failed to generate CA certificate.")
		}
	}
	return os.Chmod(keyPath, 0o600)
}
