package vm

import (
	"io"
	"os"
	"path/filepath"
	"testing"
)

// The developer's authorized_keys is read, never written. mpd used to
// append the VM's own pubkey here; it reached the runtimes anyway (via
// the id_*.pub glob) and only made the VM trust itself, so the file is
// now left exactly as the developer left it.
func TestEnsureAuthorizedKeysLeavesContentAlone(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "authorized_keys")
	own := "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAWORKSTATION petr@laptop\n"
	if err := os.WriteFile(path, []byte(own), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := ensureAuthorizedKeys(io.Discard, dir); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != own {
		t.Errorf("authorized_keys was modified:\n%q\nwant:\n%q", got, own)
	}
}

// A sandbox VM may have no workstation side at all, so the file has to
// be created — empty — for AuthorizedPublicKeys to read later.
func TestEnsureAuthorizedKeysCreatesEmptyWithMode600(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "authorized_keys")

	if err := ensureAuthorizedKeys(io.Discard, dir); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("authorized_keys not created: %v", err)
	}
	if len(body) != 0 {
		t.Errorf("expected an empty file, got %q", body)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Errorf("mode is %o, want 600 — sshd ignores a group-readable file", perm)
	}
}

// A too-permissive file left by hand is tightened, and a second run
// changes nothing.
func TestEnsureAuthorizedKeysFixesModeAndRepeats(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "authorized_keys")
	if err := os.WriteFile(path, []byte("ssh-ed25519 AAAA x@y\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	for i := 0; i < 2; i++ {
		if err := ensureAuthorizedKeys(io.Discard, dir); err != nil {
			t.Fatalf("run %d: %v", i+1, err)
		}
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if perm := info.Mode().Perm(); perm != 0o600 {
			t.Errorf("run %d: mode is %o, want 600", i+1, perm)
		}
	}
	body, _ := os.ReadFile(path)
	if string(body) != "ssh-ed25519 AAAA x@y\n" {
		t.Errorf("content changed: %q", body)
	}
}
