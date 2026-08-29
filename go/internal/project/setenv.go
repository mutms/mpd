package project

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"strings"

	"github.com/mutms/mpd/go/internal/srv"
)

// ApplyMutations writes each KEY=VALUE into an mpd.env file, in place.
func ApplyMutations(path string, muts []EnvMutation) error {
	for _, m := range muts {
		if err := SetEnvKey(path, m.Key, m.Value); err != nil {
			return fmt.Errorf("Failed to update %s (key '%s'): %w", path, m.Key, err)
		}
	}
	return nil
}

// SetEnvKey sets or unsets one key without moving it. Position is
// load-bearing: every key sits under the comment block that explains it.
// Caller must have run the key and value through ParseMutations.
func SetEnvKey(path, key, value string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	return srv.Write(path, setEnvKey(data, key, value), info.Mode().Perm())
}

func setEnvKey(data []byte, key, value string) []byte {
	var (
		setting  = key + "="       // KEY=…      an actual setting
		example  = "#" + key + "=" // #KEY=…  a commented example
		out      bytes.Buffer
		done     bool
		lastLine string
	)

	// Decided up front: a file can hold a setting and a commented
	// example in either order, and the real setting has to win.
	hasSetting := false
	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		if strings.HasPrefix(sc.Text(), setting) {
			hasSetting = true
			break
		}
	}

	sc = bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		lastLine = line
		switch {
		case strings.HasPrefix(line, setting):
			if done {
				continue // a duplicate below the one already kept
			}
			done = true
			if value != "" {
				fmt.Fprintf(&out, "%s=%s\n", key, value)
			} else {
				// Commented out rather than removed, so the key keeps
				// its place for the next set.
				fmt.Fprintf(&out, "#%s\n", line)
			}
		case strings.HasPrefix(line, example) && !hasSetting && !done && value != "":
			done = true
			fmt.Fprintf(&out, "%s=%s\n", key, value)
		default:
			fmt.Fprintf(&out, "%s\n", line)
		}
	}

	// Not in the file at all: append, one blank line clear of the end.
	if !done && value != "" {
		if lastLine != "" {
			out.WriteString("\n")
		}
		fmt.Fprintf(&out, "%s=%s\n", key, value)
	}
	return out.Bytes()
}
