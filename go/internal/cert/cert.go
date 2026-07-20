// Package cert issues the TLS certificates mpd's local CA signs.
//
// The CA itself is generated on the workstation and pushed into the VM;
// only its key material lives here, under /var/lib/mpd/conf/caroot/ —
// never on the data volume and never inside a container. Leaf certs are
// signed in the VM and written to where they are served from.
package cert

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/mutms/mpd/go/internal/exec"
)

// Paths under the private identity directory.
const (
	ConfDir     = "/var/lib/mpd/conf"
	CARootDir   = ConfDir + "/caroot"
	TempDir     = ConfDir + "/temp"
	CACertPath  = CARootDir + "/rootCA.pem"
	CAKeyPath   = CARootDir + "/rootCA-key.pem"
	LeafDaysStr = "397"
)

// Generate signs a certificate for sans, writing PEM files to certPath
// and keyPath.
//
// 397 days is not arbitrary: macOS rejects leaf certificates valid for
// 398 days or more, so a longer-lived cert would be untrusted on the
// very workstation the developer browses from.
func Generate(ctx context.Context, sans []string, certPath, keyPath string) error {
	if len(sans) == 0 {
		return fmt.Errorf("no SANs given")
	}
	if err := os.MkdirAll(TempDir, 0o700); err != nil {
		return err
	}

	csr := filepath.Join(TempDir, "tmp.csr")
	extFile := filepath.Join(TempDir, "tmp.ext")
	defer func() {
		os.Remove(csr)
		os.Remove(extFile)
	}()

	dnsList := make([]string, 0, len(sans))
	for _, s := range sans {
		dnsList = append(dnsList, "DNS:"+s)
	}
	ext := "authorityKeyIdentifier=keyid,issuer\n" +
		"basicConstraints=CA:FALSE\n" +
		"keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment\n" +
		"subjectAltName = " + strings.Join(dnsList, ", ") + "\n"
	if err := os.WriteFile(extFile, []byte(ext), 0o600); err != nil {
		return err
	}

	cn := sans[0]
	steps := [][]string{
		{"genrsa", "-out", keyPath, "2048"},
		{"req", "-new", "-key", keyPath, "-out", csr, "-subj", "/CN=" + cn},
		{"x509", "-req", "-in", csr, "-CA", CACertPath, "-CAkey", CAKeyPath,
			"-CAcreateserial", "-out", certPath, "-days", LeafDaysStr, "-extfile", extFile},
	}
	for _, args := range steps {
		res, err := exec.Capture(ctx, exec.Cmd{Name: "openssl", Args: args})
		if err != nil {
			return fmt.Errorf("openssl %s: %w", args[0], err)
		}
		if res.Code != 0 {
			return fmt.Errorf("Failed to generate certificate for %s.", cn)
		}
	}
	// The key never leaves this directory world-readable, even briefly.
	return os.Chmod(keyPath, 0o600)
}
