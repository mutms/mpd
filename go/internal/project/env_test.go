package project

import (
	"fmt"
	"strings"
	"testing"
)

// okTag accepts anything, isolating these tests from DB tag parsing.
func okTag(string) error { return nil }

func TestParseMutations(t *testing.T) {
	got, err := ParseMutations([]string{"MPD_DB=postgres:18", "MPD_PHP_VERSION=8.4"}, okTag)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 2 || got[0].Key != "MPD_DB" || got[0].Value != "postgres:18" {
		t.Fatalf("got %+v", got)
	}
}

// Empty means "unset this key", which is how a project drops back to
// the inherited default — so it must not be rejected.
func TestEmptyValueIsAllowed(t *testing.T) {
	got, err := ParseMutations([]string{"MPD_DB="}, okTag)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 1 || got[0].Value != "" {
		t.Fatalf("got %+v", got)
	}
}

func TestKeyRules(t *testing.T) {
	bad := map[string]string{
		"lowercase":      "mpd_db=x",
		"missing prefix": "DB=x",
		"empty key":      "=x",
		"punctuation":    "MPD_D-B=x",
	}
	for name, arg := range bad {
		t.Run(name, func(t *testing.T) {
			if _, err := ParseMutations([]string{arg}, okTag); err == nil {
				t.Errorf("ParseMutations(%q) = nil error, want rejection", arg)
			}
		})
	}
}

// The charset is the CLI's boundary against smuggling shell syntax into
// mpd.env. The file is parsed rather than sourced, so these could not
// execute — but they must not reach the file either.
func TestShellMetacharactersAreRejected(t *testing.T) {
	for _, value := range []string{
		"$(rm -rf ~)",
		"`id`",
		"a;b",
		"a|b",
		"a&b",
		"a>b",
		"a b",
		"a'b",
		`a"b`,
		"a\nb",
		"${HOME}",
	} {
		arg := "MPD_ANYTHING=" + value
		if _, err := ParseMutations([]string{arg}, okTag); err == nil {
			t.Errorf("value %q was accepted, want rejection", value)
		}
	}
}

func TestSafeValuesAreAccepted(t *testing.T) {
	for _, value := range []string{
		"postgres:18", "8.4", "/srv/projects/x", "a,b", "user@host", "k=v", "a+b", "a-b_c.d",
	} {
		if _, err := ParseMutations([]string{"MPD_ANYTHING=" + value}, okTag); err != nil {
			t.Errorf("value %q rejected: %v", value, err)
		}
	}
}

// MPD_DB gets the engine/version validator instead of the charset check,
// so a well-formed but unsupported engine is still refused.
func TestDBTagUsesItsOwnValidator(t *testing.T) {
	reject := func(v string) error { return fmt.Errorf("bad tag %q", v) }
	_, err := ParseMutations([]string{"MPD_DB=sqlite:3"}, reject)
	if err == nil || !strings.Contains(err.Error(), "bad tag") {
		t.Fatalf("err = %v, want the DB validator's error", err)
	}
}

func TestFlagsAreRejectedWithGuidance(t *testing.T) {
	_, err := ParseMutations([]string{"--type=moodle"}, okTag)
	if err == nil || !strings.Contains(err.Error(), "create time") {
		t.Errorf("err = %v, want it to say type is chosen at create time", err)
	}
	if _, err := ParseMutations([]string{"--wat"}, okTag); err == nil {
		t.Error("unknown flag accepted")
	}
	if _, err := ParseMutations([]string{"notapair"}, okTag); err == nil {
		t.Error("non-pair argument accepted")
	}
}
