package vm

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testPromptBody = "if [ -n \"${PS1-}\" ]; then\n    PS1=\"x\"\nfi\n"

// The developer's own ~/.bashrc content survives, and a second run is a
// no-op rather than stacking a second copy of the block.
func TestEnsurePromptMergesPreservesAndRepeats(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	path := filepath.Join(home, ".bashrc")

	own := "export EDITOR=vim\n"
	if err := os.WriteFile(path, []byte(own), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := ensurePrompt(io.Discard, testPromptBody); err != nil {
		t.Fatalf("first run: %v", err)
	}
	first, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(first), "export EDITOR=vim") {
		t.Errorf("hand-written content lost:\n%s", first)
	}
	if !strings.Contains(string(first), promptBlockStart) {
		t.Errorf("block not written:\n%s", first)
	}

	if err := ensurePrompt(io.Discard, testPromptBody); err != nil {
		t.Fatalf("second run: %v", err)
	}
	second, _ := os.ReadFile(path)
	if string(second) != string(first) {
		t.Errorf("second run changed the file:\n%s\nwant:\n%s", second, first)
	}
	if n := strings.Count(string(second), promptBlockStart); n != 1 {
		t.Errorf("got %d start markers, want 1:\n%s", n, second)
	}
}

// The block must land at the END of ~/.bashrc: Debian's own PS1
// assignment runs earlier in that file, and a block placed above it would
// simply be overwritten.
func TestEnsurePromptBlockGoesLast(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	path := filepath.Join(home, ".bashrc")

	if err := os.WriteFile(path, []byte("PS1='\\u@\\h:\\w\\$ '\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := ensurePrompt(io.Discard, testPromptBody); err != nil {
		t.Fatal(err)
	}
	body, _ := os.ReadFile(path)
	if strings.Index(string(body), "PS1=") > strings.Index(string(body), promptBlockStart) {
		t.Errorf("block precedes the distro PS1 assignment:\n%s", body)
	}
}
