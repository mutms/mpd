package services

import "testing"

// Regression: authentik's outpost list ignores `?name=`, so selecting a
// service object must match by field in Go, never trust results[0] — the
// embedded (proxy) outpost sorts first and would hand back the wrong
// token.
func TestPickMatchesByFieldNotOrder(t *testing.T) {
	outposts := []map[string]any{
		{"name": "authentik Embedded Outpost", "type": "proxy", "token_identifier": "embedded-tok"},
		{"name": "mpd-ldap", "type": "ldap", "token_identifier": "ldap-tok"},
	}
	got, ok := pick(outposts, "name", "mpd-ldap")
	if !ok {
		t.Fatal("pick did not find mpd-ldap")
	}
	if got["token_identifier"] != "ldap-tok" {
		t.Errorf("picked token %v, want ldap-tok (embedded must not win)", got["token_identifier"])
	}
	if _, ok := pick(outposts, "name", "absent"); ok {
		t.Error("pick reported a match for an absent value")
	}
}

func TestStrRendersJSONScalars(t *testing.T) {
	if got := str(float64(1)); got != "1" {
		t.Errorf("str(1.0) = %q, want 1", got)
	}
	if got := str("x"); got != "x" {
		t.Errorf("str(\"x\") = %q", got)
	}
	if got := str(nil); got != "" {
		t.Errorf("str(nil) = %q, want empty", got)
	}
}
