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

// LockName is the lock file inside the state directory. Dot-prefixed so it
// does not read as one of the state documents beside it, and skipped by
// anything globbing *.json.
const LockName = ".lock"

// lockPoll is how often a waiting caller retests the lock. Short enough to
// feel immediate, long enough to be free.
const lockPoll = 100 * time.Millisecond

// Acquire takes mpd's exclusive mutation lock and returns the release
// func.
//
// # Why a lock exists at all
//
// Every mutating verb is a read-modify-write across several files plus
// podman: UpsertProject reads the whole project list, edits one entry and
// rewrites the list. writeJSON is atomic per file, so a torn file is not
// the risk — a lost update is. Two concurrent `mpd create` calls both read
// the same list, each appends its own project, and the second write wins:
// one project silently disappears from state while its containers, its
// database and its /srv tree all exist. Nothing later reconciles that,
// because state is the record of what was asked for.
//
// Until now a single human at a single terminal serialised these by
// accident. An in-runtime entry point removes that accident, which is why
// this lands before the socket.
//
// # Scope
//
// Mutating verbs only. Read-only verbs (show, list, status) deliberately
// do not take it: making `mpd show` block behind a five-minute `mpd
// create` would trade a rare lost update for a constant annoyance, and a
// reader racing a writer sees either the old or the new file thanks to the
// atomic rename — never a partial one.
//
// # Never nest
//
// flock is per open file description, so a second Acquire in the same
// process opens a second descriptor and blocks on itself — forever. The
// lock is therefore taken at the command entry points only (cmd/mpd) and
// never from inside a cli handler, so no library call path can acquire it
// twice. Keep it that way.
func (s Store) Acquire(ctx context.Context, out io.Writer) (func(), error) {
	if err := os.MkdirAll(s.dir, 0o755); err != nil {
		return nil, fmt.Errorf("creating %s: %w", s.dir, err)
	}
	path := filepath.Join(s.dir, LockName)
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return nil, fmt.Errorf("opening %s: %w", path, err)
	}

	// Try without blocking first, so the overwhelmingly common
	// uncontended case costs one syscall and prints nothing.
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
		return releaser(f), nil
	}

	// Contended. Say so — a command that sits silently looks hung, and
	// the reason it is waiting is not guessable from the outside.
	fmt.Fprintln(out, "Waiting for another mpd command to finish…")

	// Poll rather than block in the kernel: a blocking flock cannot be
	// interrupted by context cancellation, so a cancelled command would
	// keep waiting for a lock it no longer intends to use.
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

// releaser unlocks and closes, in that order, and is safe to call twice so
// a caller may both defer it and release early.
//
// Closing the descriptor would release the lock on its own; the explicit
// LOCK_UN is kept because it states the intent at the point it happens
// rather than leaving it as a side effect of cleanup.
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
