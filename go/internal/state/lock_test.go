package state

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestAcquireUncontendedIsSilent(t *testing.T) {
	s := NewAt(t.TempDir())
	var out strings.Builder

	release, err := s.Acquire(context.Background(), &out)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	defer release()

	if out.String() != "" {
		t.Errorf("uncontended Acquire printed %q, want silence", out.String())
	}
	if _, err := os.Stat(filepath.Join(s.dir, LockName)); err != nil {
		t.Errorf("lock file not created: %v", err)
	}
}

func TestReleaseIsIdempotentAndFrees(t *testing.T) {
	s := NewAt(t.TempDir())

	release, err := s.Acquire(context.Background(), io.Discard)
	if err != nil {
		t.Fatalf("first Acquire: %v", err)
	}
	release()
	release() // must not panic, must not re-unlock someone else's lock

	second, err := s.Acquire(context.Background(), io.Discard)
	if err != nil {
		t.Fatalf("Acquire after release: %v", err)
	}
	second()
}

// A second descriptor over the same file contends exactly as another
// process would: flock is per open file description. That is also why
// Acquire must never be nested.
func TestAcquireHonoursContextWhenContended(t *testing.T) {
	dir := t.TempDir()
	s := NewAt(dir)

	held, release := holdLock(t, filepath.Join(dir, LockName))
	defer release()
	if !held {
		t.Fatal("could not take the lock to set up contention")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()

	var out strings.Builder
	start := time.Now()
	got, err := s.Acquire(ctx, &out)
	if err == nil {
		got()
		t.Fatal("Acquire succeeded while the lock was held elsewhere")
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Errorf("Acquire waited %v past its context deadline", elapsed)
	}
	if !strings.Contains(out.String(), "Waiting") {
		t.Errorf("a contended Acquire should explain the wait, got %q", out.String())
	}
}

func TestAcquireSucceedsAfterHolderReleases(t *testing.T) {
	dir := t.TempDir()
	s := NewAt(dir)

	held, release := holdLock(t, filepath.Join(dir, LockName))
	if !held {
		t.Fatal("could not take the lock to set up contention")
	}
	go func() {
		time.Sleep(200 * time.Millisecond)
		release()
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	got, err := s.Acquire(ctx, io.Discard)
	if err != nil {
		t.Fatalf("Acquire never got the lock after release: %v", err)
	}
	got()
}

// holdLock takes an exclusive flock on path via its own descriptor.
func holdLock(t *testing.T, path string) (bool, func()) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		t.Fatalf("opening %s: %v", path, err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return false, func() {}
	}
	return true, releaser(f)
}
