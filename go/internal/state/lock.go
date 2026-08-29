package state

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// LockName is the lock file inside the state directory. Dot-prefixed so
// it does not read as a state document and is skipped by *.json globs.
const LockName = ".lock"

// lockPoll is how often a waiting caller retests the lock.
const lockPoll = 100 * time.Millisecond

// Acquire takes mpd's exclusive mutation lock and returns the release
// func.
//
// Mutating verbs are read-modify-write across several files, so two
// concurrent commands would lose updates without it. Read-only verbs
// skip it on purpose: atomic renames already give readers a consistent
// file. Never nest: flock is per open file description, so a second
// Acquire in the same process blocks on itself forever. Take the lock
// only at the command entry points (cmd/mpd), never inside a cli
// handler.
func (s Store) Acquire(ctx context.Context, out io.Writer) (func(), error) {
	if err := os.MkdirAll(s.dir, 0o755); err != nil {
		return nil, fmt.Errorf("creating %s: %w", s.dir, err)
	}
	path := filepath.Join(s.dir, LockName)
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return nil, fmt.Errorf("opening %s: %w", path, err)
	}

	// Try without blocking first, so the common uncontended case costs
	// one syscall and prints nothing.
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
		return releaser(f), nil
	}

	// Contended. Say so — a silently waiting command looks hung.
	fmt.Fprintln(out, "Waiting for another mpd command to finish…")

	// Poll rather than block in the kernel: a blocking flock cannot be
	// interrupted by context cancellation.
	ticker := time.NewTicker(lockPoll)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			f.Close()
			return nil, ctx.Err()
		case <-ticker.C:
			if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
				return releaser(f), nil
			}
		}
	}
}

// releaser unlocks and closes, in that order. Safe to call twice, so a
// caller may both defer it and release early.
func releaser(f *os.File) func() {
	released := false
	return func() {
		if released {
			return
		}
		released = true
		syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}
}
