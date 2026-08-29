// Package cli implements mpd's commands and their terminal output.
// Listings share column widths and status wording so the tables line up.
package cli

import (
	"os"
	"strings"
)

// Column widths, shared by every listing.
const (
	colService = 14
	// Wide enough for the longest project status, "not initialised".
	colStatus = 16
	colIP     = 16
)

// Col pads s to width w; a longer s gets two trailing spaces instead of
// being truncated.
func Col(s string, w int) string {
	if len([]rune(s)) < w {
		return s + strings.Repeat(" ", w-len([]rune(s)))
	}
	return s + "  "
}

// Rule is the horizontal separator under a table header.
func Rule(width int) string { return strings.Repeat("─", width) }

// Status wording shared by every listing. "started" is a project's
// autostart intent, coloured like "running".
const (
	StatusRunning    = "running"
	StatusStarted    = "started"
	StatusStopped    = "stopped"
	StatusNotCreated = "not-created"
)

// colorEnabled reports whether to emit ANSI colour; piped output stays
// plain. The character-device check stands in for isatty(3) to avoid a
// cgo or x/term dependency; a non-terminal device like /dev/null gets
// colour, which is harmless.
func colorEnabled() bool {
	info, err := os.Stdout.Stat()
	if err != nil || info.Mode()&os.ModeCharDevice == 0 {
		return false
	}
	t := os.Getenv("TERM")
	return t != "" && t != "dumb"
}

// StatusLabel pads a status to width, then colours it so escape codes
// never count toward the column width.
func StatusLabel(status string, width int) string {
	padded := Col(status, width)
	if !colorEnabled() {
		return padded
	}
	switch status {
	case StatusRunning, StatusStarted:
		return "\033[32m" + padded + "\033[0m"
	case StatusStopped:
		return "\033[33m" + padded + "\033[0m"
	case StatusNotCreated:
		return "\033[31m" + padded + "\033[0m"
	default:
		return padded
	}
}
