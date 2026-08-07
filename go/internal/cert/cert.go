// Package cert issues the TLS certificates mpd's local CA signs.
//
// The CA material lives under /var/lib/mpd/conf/caroot/ — never on the
// data volume and never inside a container. Leaf certs are signed in the
// VM and written to where they are served from.
//
// Two certificates matter here and they are not the same thing. The
// **anchor** is what the VM's trust stores are told to trust; the
// **signer** is what leaf certificates are actually signed with. On a VM
// provisioned by mpd-virt the signer is an intermediate constrained to
// that VM's own zone, and the root's private key is never copied into the
// VM at all — so a compromised VM can mint certificates for its own names
// and for nothing else. On a VM set up by setup/linux or setup/windows
// the two are one self-signed certificate. Signer resolves which case a
// given VM is in; everything else here goes through it.
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
//
// KEEP IN SYNC with the same constants in internal/vm/vm.go. They are
// duplicated rather than imported because this package is otherwise
// independent of the VM-management package, and pulling that in for four
// string constants would invert the dependency.
const (
	ConfDir   = "/var/lib/mpd/conf"
	CARootDir = ConfDir + "/caroot"
	TempDir   = ConfDir + "/temp"

	// CACertPath is the trust anchor; CAKeyPath its key, present only when
	// the VM signs with the anchor directly.
	CACertPath = CARootDir + "/rootCA.pem"
	CAKeyPath  = CARootDir + "/rootCA-key.pem"

	// SigningCertPath and SigningKeyPath are the CA leaves are signed with.
	SigningCertPath = CARootDir + "/vmCA.pem"
	SigningKeyPath  = CARootDir + "/vmCA-key.pem"

	// LeafDays is the longest a leaf may live. 397 is not arbitrary: macOS
	// rejects leaf certificates valid for 398 days or more, so a
	// longer-lived cert would be untrusted on the very workstation the
	// developer browses from. A leaf can still be issued for less — see
	// leafDays.
	LeafDays = 397
)

// Signer is the CA leaf certificates are signed with.
type Signer struct {
	CertPath string
	KeyPath  string

	// Chain is true when CertPath is not the trust anchor. A client that
	// trusts only the anchor cannot verify a leaf signed by an
	// intermediate unless the intermediate travels with it, so Generate
	// appends CertPath to the leaf file it writes.
	Chain bool
}

// ResolveSigner reports which CA this VM signs with, and false when there
// is no CA material at all — a fresh VM, where the caller's answer is to
// generate one rather than to fail.
//
// The intermediate wins when present. A VM migrated by `mpd-virt
// refresh-ca` has its root key deleted, but an interrupted migration (or
// a re-run of an older mpd-virt) could leave both on disk, and in that
// state the constrained signer is the one we want — preferring the root
// would silently undo the migration.
func ResolveSigner() (Signer, bool) { return resolveSignerIn(CARootDir) }

// resolveSignerIn is ResolveSigner against an arbitrary directory, so the
// three-way decision can be tested without writing to /var/lib.
func resolveSignerIn(dir string) (Signer, bool) {
	// Basenames come from the path constants rather than being spelled
	// again, so the tested code and the production paths cannot drift.
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
			// setup/linux and setup/windows write one self-signed
			// certificate to both paths. Identical bytes mean the chain is
			// one long and there is nothing to append.
			Chain: !sameFile(signerCert, anchorCert),
		}, true
	}
	if fileExists(anchorKey) && fileExists(anchorCert) {
		// A VM provisioned before per-VM intermediates existed. It still
		// holds the root key and still signs with it, which is what it did
		// before this code shipped — `mpd-virt refresh-ca` moves it on.
		return Signer{CertPath: anchorCert, KeyPath: anchorKey}, true
	}
	return Signer{}, false
}

// leafDays is how long a leaf signed right now may live: LeafDays, unless
// the CA signing it expires sooner.
//
// Nothing may outlive its issuer. A leaf valid past its CA's expiry does
// not gracefully degrade — the whole chain fails on the CA's date, while
// the leaf still claims months of validity, so every tool reports a
// puzzle: `openssl x509 -enddate` on the leaf says it is fine and every
// client rejects it anyway.
//
// This binds in practice rather than in theory. A per-VM intermediate is
// itself capped at whatever the root has left, so on a root approaching
// renewal the signer can easily have fewer than 397 days remaining, and
// an uncapped leaf would sail past it.
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
//
// 397 days is not arbitrary: macOS rejects leaf certificates valid for
// 398 days or more, so a longer-lived cert would be untrusted on the
// very workstation the developer browses from.
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
	// The key never leaves this directory world-readable, even briefly.
	return os.Chmod(keyPath, 0o600)
}

// appendChain concatenates the signing CA onto the leaf file, leaf first.
//
// Everything that serves these files hands the whole file to the client:
// caddy's `tls <cert> <key>` — the VM's own and the in-runtime frontdoor.
// So the file *is* the chain, and a leaf alone would fail verification
// everywhere the intermediate is not already installed — which is
// everywhere, since only the root is ever distributed.
//
// Leaf first is not a stylistic choice: TLS requires the end-entity
// certificate to come first in the chain the server sends.
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
