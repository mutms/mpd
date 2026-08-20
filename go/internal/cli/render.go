// Package cli renders mpd's terminal output.
//
// Column widths, separator lengths and status wording were reproduced
// from the implementation this replaced, and verified by diffing the two
// binaries' output. That constraint is gone now — they can be redesigned
// — but keep them consistent across listings: the tables are meant to
// line up with each other.
package cli

import (
	"os"
	"strings"
)

// Column widths, shared by every listing so the tables line up.
const (
	colService = 14
	// Wide enough for the longest project status, "not initialised".
	colStatus = 16
	colIP     = 16
)

// Col left-pads s to width w. The obvious implementation truncates when
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

// Status wording used across every listing. "running"/"stopped" are the
// live container words (databases, services, infra); "started" is a
// project's autostart intent, coloured like "running".
const (
	StatusRunning    = "running"
	StatusStarted    = "started"
	StatusStopped    = "stopped"
	StatusNotCreated = "not-created"
)

// colorEnabled reports whether to emit ANSI colour: only for a real
// terminal with a usable TERM. Piped output — including the differential
// tests — stays plain.
//
// The character-device check stands in for an isatty(3) ioctl, which
// would mean a cgo or golang.org/x/term dependency. x/term is not worth
// it: its release train requires a newer Go than Debian Trixie ships, so
// pulling it in makes every VM download a 210 MB toolchain to build mpd.
// The one behavioural difference is that a character device which is not
// a terminal — /dev/null, most obviously — reads as one here, and
// colouring output nobody reads costs nothing.
func colorEnabled() bool {
	info, err := os.Stdout.Stat()
	if err != nil || info.Mode()&os.ModeCharDevice == 0 {
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
