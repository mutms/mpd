package cli

import (
	"strings"
	"testing"
)

// promptName guards the two verbs that destroy data irrecoverably, so what
// matters is that only the exact name gets through.
func TestPromptNameAcceptsOnlyTheExactName(t *testing.T) {
	for _, input := range []string{
		"moodle45\n",
		"moodle45",     // no trailing newline (piped input)
		"  moodle45  ", // padding from a copy-paste
		"moodle45\r\n", // CRLF
	} {
		var out strings.Builder
		if !promptName(&out, strings.NewReader(input), "moodle45", "reset") {
			t.Errorf("input %q should confirm", input)
		}
	}
}

func TestPromptNameRejectsAnythingElse(t *testing.T) {
	for _, input := range []string{
		"",            // EOF: no answer is not an answer
		"\n",          // bare Enter
		"y\n",         // the reflex the typed name exists to defeat
		"yes\n",       // ditto
		"moodle4\n",   // near miss
		"moodle451\n", // near miss the other way
		"MOODLE45\n",  // case matters: project names are lowercase by construction
		"other\n",
		"moodle45 extra\n",
	} {
		var out strings.Builder
		if promptName(&out, strings.NewReader(input), "moodle45", "reset") {
			t.Errorf("input %q should NOT confirm", input)
		}
	}
}

// The prompt has to show the name, since typing it back is the confirmation.
func TestPromptNameShowsNameAndAction(t *testing.T) {
	var out strings.Builder
	promptName(&out, strings.NewReader("\n"), "moodle45", "deletion")
	got := out.String()
	for _, want := range []string{"moodle45", "deletion", "abort"} {
		if !strings.Contains(got, want) {
			t.Errorf("prompt should mention %q, got: %q", want, got)
		}
	}
}

// A confirmation for one project must not confirm another: this is the case
// that y/N could not distinguish at all.
func TestPromptNameIsProjectSpecific(t *testing.T) {
	var out strings.Builder
	if promptName(&out, strings.NewReader("moodle45\n"), "prod-site", "deletion") {
		t.Error("typing a different project's name must not confirm")
	}
}
