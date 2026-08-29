package cert

import (
	"os"
	osexec "os/exec"
	"path/filepath"
	"strconv"
	"testing"
)

// testExec runs a command and returns 0 on success, non-zero otherwise.
func testExec(t *testing.T, name string, args ...string) int {
	t.Helper()
	if err := osexec.Command(name, args...).Run(); err != nil {
		return 1
	}
	return 0
}

// write puts content at dir/name.
func write(t *testing.T, dir, name, content string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("writing fixture %s: %v", path, err)
	}
	return path
}

// TestResolveSigner covers the states a caroot directory can be in.
func TestResolveSigner(t *testing.T) {
	const (
		anchorPEM = "-----BEGIN CERTIFICATE-----\nanchor\n-----END CERTIFICATE-----\n"
		interPEM  = "-----BEGIN CERTIFICATE-----\nintermediate\n-----END CERTIFICATE-----\n"
	)

	t.Run("mpd-virt VM signs with the constrained intermediate", func(t *testing.T) {
		dir := t.TempDir()
		write(t, dir, "rootCA.pem", anchorPEM)
		write(t, dir, "vmCA.pem", interPEM)
		write(t, dir, "vmCA-key.pem", "key")

		got, ok := resolveSignerIn(dir)
		if !ok {
			t.Fatal("expected a signer")
		}
		if got.KeyPath != filepath.Join(dir, "vmCA-key.pem") {
			t.Errorf("signed with %s, want the intermediate key", got.KeyPath)
		}
		if !got.Chain {
			t.Error("Chain = false; an intermediate must be sent with the leaf or nothing can verify it")
		}
	})

	t.Run("self-signed VM has anchor and signer as one cert", func(t *testing.T) {
		// A sandbox VM writes the same certificate to both paths.
		dir := t.TempDir()
		write(t, dir, "rootCA.pem", anchorPEM)
		write(t, dir, "vmCA.pem", anchorPEM)
		write(t, dir, "vmCA-key.pem", "key")

		got, ok := resolveSignerIn(dir)
		if !ok {
			t.Fatal("expected a signer")
		}
		if got.Chain {
			t.Error("Chain = true, but signer and anchor are the same certificate")
		}
	})

	t.Run("pre-migration VM still signs with the root", func(t *testing.T) {
		// A VM provisioned before per-VM intermediates must keep working
		// until `mpd-virt refresh-ca` migrates it.
		dir := t.TempDir()
		write(t, dir, "rootCA.pem", anchorPEM)
		write(t, dir, "rootCA-key.pem", "key")

		got, ok := resolveSignerIn(dir)
		if !ok {
			t.Fatal("expected a signer")
		}
		if got.KeyPath != filepath.Join(dir, "rootCA-key.pem") {
			t.Errorf("signed with %s, want the root key", got.KeyPath)
		}
		if got.Chain {
			t.Error("Chain = true, but the root signed directly")
		}
	})

	t.Run("interrupted migration prefers the intermediate", func(t *testing.T) {
		// Both keys present: refresh-ca pushed the intermediate but died
		// before deleting the root key. The root must not win here.
		dir := t.TempDir()
		write(t, dir, "rootCA.pem", anchorPEM)
		write(t, dir, "rootCA-key.pem", "root-key")
		write(t, dir, "vmCA.pem", interPEM)
		write(t, dir, "vmCA-key.pem", "vm-key")

		got, ok := resolveSignerIn(dir)
		if !ok {
			t.Fatal("expected a signer")
		}
		if got.KeyPath != filepath.Join(dir, "vmCA-key.pem") {
			t.Errorf("signed with %s, want the intermediate even though the root key is still present", got.KeyPath)
		}
	})

	t.Run("empty caroot has no signer", func(t *testing.T) {
		// Absence, not an error: the caller's answer is to generate a CA.
		if _, ok := resolveSignerIn(t.TempDir()); ok {
			t.Error("expected no signer in an empty directory")
		}
	})

	t.Run("a key without its certificate is not a signer", func(t *testing.T) {
		dir := t.TempDir()
		write(t, dir, "vmCA-key.pem", "key")
		if _, ok := resolveSignerIn(dir); ok {
			t.Error("expected no signer when the certificate is missing")
		}
	})
}

// TestLeafDays pins the rule that a leaf never outlives its issuer.
// Regression: leaves once got a flat 397 days and outlived a short CA.
func TestLeafDays(t *testing.T) {
	dir := t.TempDir()

	makeCA := func(name string, days int) string {
		key := filepath.Join(dir, name+"-key.pem")
		crt := filepath.Join(dir, name+".pem")
		cmd := testExec(t, "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
			"-keyout", key, "-out", crt, "-days", strconv.Itoa(days), "-subj", "/CN="+name)
		if cmd != 0 {
			t.Skipf("openssl unavailable; skipping")
		}
		return crt
	}

	t.Run("long-lived CA gives a full-length leaf", func(t *testing.T) {
		got, err := leafDays(makeCA("long", 3650))
		if err != nil {
			t.Fatal(err)
		}
		if got != LeafDays {
			t.Errorf("leafDays = %d, want %d (the macOS 398-day ceiling)", got, LeafDays)
		}
	})

	t.Run("short-lived CA caps the leaf", func(t *testing.T) {
		got, err := leafDays(makeCA("short", 30))
		if err != nil {
			t.Fatal(err)
		}
		if got >= LeafDays {
			t.Errorf("leafDays = %d, want it capped below %d", got, LeafDays)
		}
		if got > 30 {
			t.Errorf("leafDays = %d, longer than the CA's own 30 days", got)
		}
	})

	t.Run("missing CA is an error, not a default", func(t *testing.T) {
		if _, err := leafDays(filepath.Join(dir, "nope.pem")); err == nil {
			t.Error("expected an error for a missing signing CA")
		}
	})
}

// TestSelfSignedInstallPath covers a VM with no CA material: --vm-setup
// generates one CA as both anchor and signer, and Chain must be false.
func TestSelfSignedInstallPath(t *testing.T) {
	dir := t.TempDir()
	signerCert := filepath.Join(dir, filepath.Base(SigningCertPath))
	signerKey := filepath.Join(dir, filepath.Base(SigningKeyPath))
	anchor := filepath.Join(dir, filepath.Base(CACertPath))

	if _, ok := resolveSignerIn(dir); ok {
		t.Fatal("expected no signer before generation")
	}

	if err := GenerateCA(t.Context(), signerKey, signerCert); err != nil {
		t.Skipf("GenerateCA unavailable here (needs openssl + %s): %v", TempDir, err)
	}
	// setupCertificates publishes the self-signed CA as its own anchor.
	data, err := os.ReadFile(signerCert)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(anchor, data, 0o644); err != nil {
		t.Fatal(err)
	}

	got, ok := resolveSignerIn(dir)
	if !ok {
		t.Fatal("expected a signer after generation")
	}
	if got.CertPath != signerCert {
		t.Errorf("signed with %s, want %s", got.CertPath, signerCert)
	}
	if got.Chain {
		t.Error("Chain = true, but anchor and signer are the same self-signed certificate")
	}
	days, err := leafDays(got.CertPath)
	if err != nil || days <= 0 {
		t.Errorf("leafDays = %d, %v; want a positive lifetime", days, err)
	}
}

// TestAppendChain checks the leaf comes first, as TLS requires.
func TestAppendChain(t *testing.T) {
	dir := t.TempDir()
	leaf := write(t, dir, "cert.pem", "LEAF")
	ca := write(t, dir, "vmCA.pem", "CA\n")

	if err := appendChain(leaf, ca); err != nil {
		t.Fatalf("appendChain: %v", err)
	}
	got, err := os.ReadFile(leaf)
	if err != nil {
		t.Fatal(err)
	}
	// The leaf fixture lacks a trailing newline on purpose: PEM blocks
	// concatenated without one cannot be parsed.
	if string(got) != "LEAF\nCA\n" {
		t.Errorf("chain = %q, want leaf then CA with a separating newline", got)
	}
}
