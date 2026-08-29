package cli

import (
	"strings"
	"testing"
	"time"
)

// A stamp mpd cannot parse must still be shown — hiding it would look
// the same as "never recorded".
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

// An unexpected `ip route get` shape must yield "", never a wrong
// device name that reads as a confident all-clear.
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

// Both samples are real `loginctl list-sessions --no-legend` output
// from a VM where the RDP collision happened.
func TestSeatSessionOf(t *testing.T) {
	// Console login present: skodak holds seat0 on tty2.
	const colliding = `      1 1000 skodak     -     735    manager       -    no   -
     11 1000 skodak     seat0 22666  user          tty2 no   -
     12 1000 skodak     -     34381  user          -    no   -
     c4 1000 skodak     -     35800  user          -    no   -`

	// After logout: only gdm's greeter holds a seat, a different user.
	const clear = `      1 1000 skodak     -     735    manager       -    no   -
     12 1000 skodak     -     34381  user          -    no   -
     13  105 Debian-gdm -     36211  manager-early -    no   -
     c5  105 Debian-gdm seat0 36200  greeter       tty1 no   -`

	if got := seatSessionOf(colliding, "skodak"); got != "11" {
		t.Errorf("seatSessionOf(colliding) = %q, want \"11\"", got)
	}
	if got := seatSessionOf(clear, "skodak"); got != "" {
		t.Errorf("seatSessionOf(clear) = %q, want \"\" (greeter is not a login)", got)
	}
	if got := seatSessionOf("", "skodak"); got != "" {
		t.Errorf("seatSessionOf(empty) = %q, want \"\"", got)
	}
}

// Real /etc/gdm3/daemon.conf samples. Switching autologin off leaves
// AutomaticLogin naming a user — the false positive to avoid.
func TestParseGDMAutoLogin(t *testing.T) {
	const on = `# GDM configuration storage

[daemon]
AutomaticLoginEnable=True
AutomaticLogin=skodak
# Uncomment the line below to force the login screen to use Xorg
#WaylandEnable=false

# Enabling automatic login
#  AutomaticLoginEnable = true
#  AutomaticLogin = user1

[security]
`
	const off = `# GDM configuration storage

[daemon]
AutomaticLoginEnable=False
AutomaticLogin=skodak

[security]
`
	if got := parseGDMAutoLogin(on); got != "skodak" {
		t.Errorf("parseGDMAutoLogin(on) = %q, want \"skodak\"", got)
	}
	if got := parseGDMAutoLogin(off); got != "" {
		t.Errorf("parseGDMAutoLogin(off) = %q, want \"\" — the key still names a user", got)
	}
	// A commented-out example must never be read as configuration.
	if got := parseGDMAutoLogin("[daemon]\n#  AutomaticLoginEnable = true\n#  AutomaticLogin = user1\n"); got != "" {
		t.Errorf("parseGDMAutoLogin(comments only) = %q, want \"\"", got)
	}
	// Enabled with no user named is not an autologin.
	if got := parseGDMAutoLogin("[daemon]\nAutomaticLoginEnable=true\n"); got != "" {
		t.Errorf("parseGDMAutoLogin(no user) = %q, want \"\"", got)
	}
}
