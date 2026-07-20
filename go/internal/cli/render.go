// Package cli renders mpd's terminal output.
//
// Output is a compatibility surface during the port: the Go binary is
// verified by diffing its output against the Swift one, so column widths,
// separator lengths and status wording are reproduced deliberately rather
// than redesigned. Change them after the flag day, not before.
package cli

import (
	"os"
	"strings"

	"golang.org/x/term"
)

// Column widths, matching mpd/CLI/Status.swift.
const (
	colService = 14
	colStatus  = 12
	colIP      = 16
)

// Col left-pads s to width w. Swift's `padding(toLength:)` truncates when
// the string is longer than the column; mpd's helper instead appends two
// spaces so nothing is lost. Reproduced exactly.
func Col(s string, w int) string {
	if len([]rune(s)) < w {
		return s + strings.Repeat(" ", w-len([]rune(s)))
	}
	return s + "  "
}

// Rule is the horizontal separator under a table header.
func Rule(width int) string { return strings.Repeat("─", width) }

// Status wording used across every listing.
const (
	StatusRunning    = "running"
	StatusStopped    = "stopped"
	StatusNotCreated = "not-created"
)

// colorEnabled reports whether to emit ANSI colour: only for a real
// terminal with a usable TERM. Piped output — including the differential
// tests against the Swift binary — stays plain.
func colorEnabled() bool {
	if !term.IsTerminal(int(os.Stdout.Fd())) {
		return false
	}
	t := os.Getenv("TERM")
	return t != "" && t != "dumb"
}

// StatusLabel pads a status to width and colours it when the terminal
// supports it. Padding happens before colouring so escape codes never
// count toward the column width.
func StatusLabel(status string, width int) string {
	padded := Col(status, width)
	if !colorEnabled() {
		return padded
	}
	switch status {
	case StatusRunning:
		return "\033[32m" + padded + "\033[0m"
	case StatusStopped:
		return "\033[33m" + padded + "\033[0m"
	case StatusNotCreated:
		return "\033[31m" + padded + "\033[0m"
	default:
		return padded
	}
}
