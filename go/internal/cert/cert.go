// Package cert issues the TLS certificates mpd's local CA signs.
// CA material lives under /var/lib/mpd/conf/caroot/, never in a container.
// Trust anchor and signer differ on managed VMs; see docs/security.md.
package cert

import (
	"bytes"
	"context"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/mutms/mpd/go/internal/exec"
)

// Paths under the private identity directory.
// KEEP IN SYNC with internal/vm/vm.go; duplicated to avoid a dependency
// on the VM-management package.
const (
	ConfDir   = "/var/lib/mpd/conf"
	CARootDir = ConfDir + "/caroot"
	TempDir   = ConfDir + "/temp"

	// CACertPath is the trust anchor; CAKeyPath its key, present only when
	// the VM signs with the anchor directly.
	CACertPath = CARootDir + "/rootCA.pem"
	CAKeyPath  = CARootDir + "/rootCA-key.pem"

	// SigningCertPath and SigningKeyPath locate the CA that signs leaves.
	SigningCertPath = CARootDir + "/vmCA.pem"
	SigningKeyPath  = CARootDir + "/vmCA-key.pem"

	// LeafDays caps leaf validity: macOS rejects leaves valid 398 days or
	// more (see docs/security.md).
	LeafDays = 397
)

// Signer is the CA leaf certificates are signed with.
type Signer struct {
	CertPath string
	KeyPath  string

	// Chain is true when CertPath is not the trust anchor; Generate then
	// appends CertPath to the leaf file so clients can verify the chain.
	Chain bool
}

// ResolveSigner reports which CA this VM signs with; false means no CA
// material exists yet. When both root key and intermediate are on disk,
// the intermediate wins — preferring the root would undo a CA migration.
func ResolveSigner() (Signer, bool) { return resolveSignerIn(CARootDir) }

func resolveSignerIn(dir string) (Signer, bool) {
	// Basenames come from the path constants so tests and production
	// paths cannot drift.
	var (
		anchorCert = filepath.Join(dir, filepath.Base(CACertPath))
		anchorKey  = filepath.Join(dir, filepath.Base(CAKeyPath))
		signerCert = filepath.Join(dir, filepath.Base(SigningCertPath))
		signerKey  = filepath.Join(dir, filepath.Base(SigningKeyPath))
	)
	if fileExists(signerKey) && fileExists(signerCert) {
		return Signer{
			CertPath: signerCert,
			KeyPath:  signerKey,
			// A sandbox writes one self-signed cert to both paths;
			// identical bytes mean there is no chain to append.
			Chain: !sameFile(signerCert, anchorCert),
		}, true
	}
	if fileExists(anchorKey) && fileExists(anchorCert) {
		// Pre-intermediate VM: it still signs with the root key until
		// `mpd-virt refresh-ca` migrates it.
		return Signer{CertPath: anchorCert, KeyPath: anchorKey}, true
	}
	return Signer{}, false
}

// leafDays caps a new leaf at LeafDays or the signing CA's remaining
// validity, whichever is less. A leaf must not outlive its issuer.
func leafDays(signerCertPath string) (int, error) {
	data, err := os.ReadFile(signerCertPath)
	if err != nil {
		return 0, fmt.Errorf("reading signing CA %s: %w", signerCertPath, err)
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return 0, fmt.Errorf("signing CA %s is not PEM", signerCertPath)
	}
	ca, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return 0, fmt.Errorf("parsing signing CA %s: %w", signerCertPath, err)
	}
	remaining := int(time.Until(ca.NotAfter).Hours() / 24)
	if remaining <= 0 {
		return 0, fmt.Errorf(
			"The signing CA %s expired on %s. Renew it before issuing certificates.",
			signerCertPath, ca.NotAfter.Format("2006-01-02"))
	}
	return min(LeafDays, remaining), nil
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func sameFile(a, b string) bool {
	da, err := os.ReadFile(a)
	if err != nil {
		return false
	}
	db, err := os.ReadFile(b)
	if err != nil {
		return false
	}
	return bytes.Equal(da, db)
}

// Generate signs a certificate for sans, writing PEM files to certPath
// and keyPath.
func Generate(ctx context.Context, sans []string, certPath, keyPath string) error {
	if len(sans) == 0 {
		return fmt.Errorf("no SANs given")
	}
	signer, ok := ResolveSigner()
	if !ok {
		return fmt.Errorf("Root CA material missing or invalid: %s", CARootDir)
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

	days, err := leafDays(signer.CertPath)
	if err != nil {
		return err
	}

	cn := sans[0]
	steps := [][]string{
		{"genrsa", "-out", keyPath, "2048"},
		{"req", "-new", "-key", keyPath, "-out", csr, "-subj", "/CN=" + cn},
		{"x509", "-req", "-in", csr, "-CA", signer.CertPath, "-CAkey", signer.KeyPath,
			"-CAcreateserial", "-out", certPath, "-days", strconv.Itoa(days), "-extfile", extFile},
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
	if signer.Chain {
		if err := appendChain(certPath, signer.CertPath); err != nil {
			return err
		}
	}
	return os.Chmod(keyPath, 0o600)
}

// appendChain concatenates the signing CA onto the leaf file. Leaf must
// come first: TLS requires the end-entity certificate first in the chain.
func appendChain(certPath, caPath string) error {
	ca, err := os.ReadFile(caPath)
	if err != nil {
		return fmt.Errorf("reading signing CA %s: %w", caPath, err)
	}
	leaf, err := os.ReadFile(certPath)
	if err != nil {
		return fmt.Errorf("reading leaf %s: %w", certPath, err)
	}
	if !bytes.HasSuffix(leaf, []byte("\n")) {
		leaf = append(leaf, '\n')
	}
	return os.WriteFile(certPath, append(leaf, ca...), 0o644)
}
