package cli

import (
	"strings"
	"testing"
	"time"
)

// diagWhen renders the recorded upgrade timestamp. The fallback matters
// most: a stamp mpd cannot parse must still be shown, because hiding it
// would turn "recorded, in a format I do not know" into the same output
// as "never recorded".
func TestDiagWhen(t *testing.T) {
	for _, tc := range []struct {
		name  string
		stamp string
		want  string
	}{
		{
			name:  "unparseable stamp is passed through",
			stamp: "last tuesday",
			want:  "last tuesday",
		},
		{
			name:  "empty stamp is passed through",
			stamp: "",
			want:  "",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := diagWhen(tc.stamp); got != tc.want {
				t.Errorf("diagWhen(%q) = %q, want %q", tc.stamp, got, tc.want)
			}
		})
	}

	t.Run("today", func(t *testing.T) {
		now := time.Now().UTC().Format(time.RFC3339)
		got := diagWhen(now)
		if !strings.Contains(got, "(today)") {
			t.Errorf("diagWhen(now) = %q, want it to say today", got)
		}
	})

	t.Run("days ago", func(t *testing.T) {
		then := time.Now().UTC().Add(-72 * time.Hour).Format(time.RFC3339)
		got := diagWhen(then)
		if !strings.Contains(got, "3 days ago") {
			t.Errorf("diagWhen(-72h) = %q, want it to say 3 days ago", got)
		}
	})
}

// routeDevice reads the interface out of `ip route get`. It is the VPN
// tripwire's parser, so an unexpected shape must yield "" — which the
// caller reports as "could not read" — rather than a wrong device name
// that would read as a confident all-clear.
func TestRouteDevice(t *testing.T) {
	for _, tc := range []struct {
		name string
		out  string
		want string
	}{
		{
			name: "bridge route",
			out:  "10.163.200.2 dev mpdbr0 src 10.163.200.1 uid 1000 \n    cache",
			want: "mpdbr0",
		},
		{
			name: "tunnel has claimed the subnet",
			out:  "10.163.200.2 dev utun4 src 100.64.0.2 uid 1000 \n    cache",
			want: "utun4",
		},
		{
			name: "via a gateway first",
			out:  "10.163.200.2 via 10.1.1.1 dev ens18 src 10.1.10.200 uid 1000",
			want: "ens18",
		},
		{
			name: "no device in output",
			out:  "10.163.200.2 unreachable",
			want: "",
		},
		{
			name: "dangling dev is not a device",
			out:  "10.163.200.2 dev",
			want: "",
		},
		{
			name: "empty",
			out:  "",
			want: "",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := routeDevice(tc.out); got != tc.want {
				t.Errorf("routeDevice(%q) = %q, want %q", tc.out, got, tc.want)
			}
		})
	}
}
