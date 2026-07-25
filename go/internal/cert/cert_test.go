package cert

import (
	"os"
	osexec "os/exec"
	"path/filepath"
	"strconv"
	"testing"
)

// testExec runs a command and returns 0 on success, non-zero otherwise, so
// a fixture can be built with the same openssl production signs with.
func testExec(t *testing.T, name string, args ...string) int {
	t.Helper()
	if err := osexec.Command(name, args...).Run(); err != nil {
		return 1
	}
	return 0
}

// write puts content at dir/name, failing the test rather than the code
// under test if the fixture itself cannot be created.
func write(t *testing.T, dir, name, content string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("writing fixture %s: %v", path, err)
	}
	return path
}

// TestResolveSigner covers the four states a caroot directory can be in.
// Which certificate signs — and whether it has to travel with the leaf —
// is the whole security property of per-VM CAs, and every case here
// corresponds to a real provisioning path.
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
		// setup/linux and setup/windows write the same certificate to both
		// paths. The chain is one long, so appending it to every leaf would
		// ship the trust anchor to clients that already have it.
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
		// Every VM provisioned before per-VM intermediates. It must keep
		// working untouched until `mpd-virt refresh-ca` moves it on.
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
		// before deleting the root key. Preferring the root here would
		// silently undo the migration on the next --vm-setup.
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
		// The caller's answer is to generate a CA, not to fail, so this
		// must be reported as absence rather than as an error.
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

// TestLeafDays covers the rule that nothing outlives its issuer.
//
// The regression this pins down was real: a per-VM intermediate capped at
// the root's remaining ~300 days signed leaves for a flat 397, so every
// leaf outlived its own CA by three months and the whole chain would have
// failed on the intermediate's date while the leaves still read as valid.
func TestLeafDays(t *testing.T) {
	dir := t.TempDir()

	// A CA with a known remaining lifetime, in PEM, is easiest to make by
	// asking openssl for one — the same tool that signs in production.
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

// TestSelfSignedInstallPath covers what a VM with no CA material does —
// the sandbox VM (id 000) and the setup/linux, setup/windows flows before
// anything is pushed in.
//
// Those installs have no orchestrator to hand them an intermediate, so
// --vm-setup generates one CA and uses it as both anchor and signer. The
// property that matters is Chain == false: appending the signer to every
// leaf would ship the trust anchor to clients that already have it, and a
// self-signed certificate is not an intermediate.
func TestSelfSignedInstallPath(t *testing.T) {
	dir := t.TempDir()
	signerCert := filepath.Join(dir, filepath.Base(SigningCertPath))
	signerKey := filepath.Join(dir, filepath.Base(SigningKeyPath))
	anchor := filepath.Join(dir, filepath.Base(CACertPath))

	// Empty caroot: no signer at all, which is the caller's cue to make one.
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
	// And it must still be usable as a signer: leaves get a real lifetime.
	days, err := leafDays(got.CertPath)
	if err != nil || days <= 0 {
		t.Errorf("leafDays = %d, %v; want a positive lifetime", days, err)
	}
}

// TestAppendChain checks the leaf comes first. TLS requires the
// end-entity certificate at the head of the chain the server sends, and
// getting it backwards fails in clients rather than at write time.
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
	// The leaf fixture deliberately lacks a trailing newline: PEM blocks
	// concatenated without one produce a file openssl cannot parse.
	if string(got) != "LEAF\nCA\n" {
		t.Errorf("chain = %q, want leaf then CA with a separating newline", got)
	}
}
