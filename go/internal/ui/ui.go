// Package ui holds the output shapes that structure every mpd command's
// transcript. Colour is unconditional, not TTY-dependent, so a piped
// transcript is identical to one seen on a terminal.
package ui

import (
	"fmt"
	"io"
)

// Step prints a section heading.
func Step(out io.Writer, format string, args ...any) {
	fmt.Fprintf(out, "\n\033[1m==> %s\033[0m\n", fmt.Sprintf(format, args...))
}

// OK prints a success line.
func OK(out io.Writer, format string, args ...any) {
	fmt.Fprintf(out, "\033[1;32m✓ %s\033[0m\n", fmt.Sprintf(format, args...))
}

// Note prints an indented informational line.
func Note(out io.Writer, format string, args ...any) {
	fmt.Fprintf(out, "  %s\n", fmt.Sprintf(format, args...))
}

// Warn prints an indented warning for a non-fatal problem.
func Warn(out io.Writer, format string, args ...any) {
	fmt.Fprintf(out, "  Warning: %s\n", fmt.Sprintf(format, args...))
}

// Fail prints a failure line for a check that did not pass. Read-only
// commands use it; a mutating command returns an error instead.
func Fail(out io.Writer, format string, args ...any) {
	fmt.Fprintf(out, "\033[1;31m✗ %s\033[0m\n", fmt.Sprintf(format, args...))
}
