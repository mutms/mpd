// Package ui holds the two output shapes that structure every mpd
// command's transcript: a step heading and a success line.
//
// They live in their own package because setup drives them from three
// layers at once — internal/cli orchestrates, internal/vm does host
// work, internal/service does container work — and a transcript that
// changes shape halfway through reads as if something went wrong.
//
// Colour is unconditional rather than TTY-dependent, so a transcript
// captured through a pipe is identical to one seen on a terminal — which
// is what makes setup output reproducible enough to diff.
package ui

import (
	"fmt"
	"io"
)

// Step prints a section heading — the blank line above it separates
// phases in a long setup transcript.
func Step(out io.Writer, format string, args ...any) {
	fmt.Fprintf(out, "\n\033[1m==> %s\033[0m\n", fmt.Sprintf(format, args...))
}

// OK prints a success line.
func OK(out io.Writer, format string, args ...any) {
	fmt.Fprintf(out, "\033[1;32m✓ %s\033[0m\n", fmt.Sprintf(format, args...))
}

// Note prints an indented informational line: something the user may
// want to know that is neither a new phase nor a success.
func Note(out io.Writer, format string, args ...any) {
	fmt.Fprintf(out, "  %s\n", fmt.Sprintf(format, args...))
}

// Warn prints an indented warning for a non-fatal problem — a step that
// could not be completed but does not make the VM unusable.
func Warn(out io.Writer, format string, args ...any) {
	fmt.Fprintf(out, "  Warning: %s\n", fmt.Sprintf(format, args...))
}

// Fail prints a failure line: the mirror of OK, for a check that did not
// pass. Read-only commands use it to report a broken state they are not
// going to fix; a command that mutates should return an error instead.
func Fail(out io.Writer, format string, args ...any) {
	fmt.Fprintf(out, "\033[1;31m✗ %s\033[0m\n", fmt.Sprintf(format, args...))
}
