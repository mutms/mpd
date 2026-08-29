package dnsmasq

import (
	"sort"
	"strings"
)

// Record is one hosts(5) line: an address and the names that answer with
// it. The first name is the canonical one; the rest are aliases.
type Record struct {
	IP    string
	Names []string
}

// The managed block's fences. The splice matches these exact lines
// after trimming whitespace.
const (
	BlockStart = "# BEGIN mpd"
	BlockEnd   = "# END mpd"
)

// Render produces the managed block, fences included. Records are
// written in the order given; sorting is the caller's choice.
func Render(zone string, records []Record) string {
	var b strings.Builder
	b.WriteString(BlockStart + "\n")
	b.WriteString("# DNS records for " + zone + ", managed by mpd. Edits are overwritten.\n")
	for _, r := range records {
		if r.IP == "" || len(r.Names) == 0 {
			continue
		}
		b.WriteString(r.IP + " " + strings.Join(r.Names, " ") + "\n")
	}
	b.WriteString(BlockEnd + "\n")
	return b.String()
}

// Splice returns the hosts file with mpd's block replaced by block, or
// appended when the file has none. Everything outside the fences is kept
// byte for byte. Every fenced span is removed, so a duplicated block
// collapses to one; an unterminated BlockStart drops the rest of the
// file, since only a truncated mpd write produces one. Idempotent:
// Splice(Splice(x, b), b) == Splice(x, b).
func Splice(existing, block string) string {
	var kept []string
	skipping := false
	for _, line := range strings.Split(existing, "\n") {
		trimmed := strings.TrimSpace(line)
		switch {
		case trimmed == BlockStart:
			skipping = true
		case trimmed == BlockEnd:
			skipping = false
		case !skipping:
			kept = append(kept, line)
		}
	}
	for len(kept) > 0 && strings.TrimSpace(kept[len(kept)-1]) == "" {
		kept = kept[:len(kept)-1]
	}

	var b strings.Builder
	if len(kept) > 0 {
		b.WriteString(strings.Join(kept, "\n"))
		b.WriteString("\n\n")
	}
	b.WriteString(strings.TrimRight(block, "\n"))
	b.WriteString("\n")
	return b.String()
}

// sortRecords orders a group by canonical name for a stable block.
func sortRecords(records []Record) {
	sort.Slice(records, func(i, j int) bool {
		return records[i].Names[0] < records[j].Names[0]
	})
}
