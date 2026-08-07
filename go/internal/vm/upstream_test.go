package vm

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The fixtures are real /run/systemd/resolve/resolv.conf content: the
// first from a Proxmox VM where systemd-networkd manages the link, the
// second from an Apple-virtualisation guest where it manages nothing and
// the only entry left is mpd's own resolver — the state where dnsmasq
// logs "ignoring nameserver <ip> - local interface" and forwards nowhere.
func TestUpstreamsExcluding(t *testing.T) {
	const healthy = `# This is /run/systemd/resolve/resolv.conf managed by man:systemd-resolved(8).
nameserver 10.163.131.1
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 2001:4860:4860::8888
search .
`
	const noUpstream = `# This is /run/systemd/resolve/resolv.conf managed by man:systemd-resolved(8).
nameserver 10.163.132.1
search .
`

	cases := []struct {
		name string
		body string
		own  string
		want []string
	}{
		{
			name: "real upstreams survive, mpd's own resolver is dropped",
			body: healthy,
			own:  "10.163.131.1",
			want: []string{"8.8.8.8", "8.8.4.4", "2001:4860:4860::8888"},
		},
		{
			name: "only mpd's own resolver leaves nothing to forward to",
			body: noUpstream,
			own:  "10.163.132.1",
			want: nil,
		},
		{
			// The comment line names a nameserver in prose; a parser that
			// searches rather than reads fields would pick it up.
			name: "commentary is not a nameserver",
			body: "# nameserver 1.2.3.4 would be wrong\nnameserver 9.9.9.9\n",
			own:  "10.163.132.1",
			want: []string{"9.9.9.9"},
		},
		{
			name: "a missing file is not an upstream",
			body: "",
			own:  "10.163.132.1",
			want: nil,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "resolv.conf")
			if tc.body != "" {
				if err := os.WriteFile(path, []byte(tc.body), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			got := upstreamsExcluding(path, tc.own)
			if strings.Join(got, ",") != strings.Join(tc.want, ",") {
				t.Errorf("upstreamsExcluding = %v, want %v", got, tc.want)
			}
		})
	}
}
