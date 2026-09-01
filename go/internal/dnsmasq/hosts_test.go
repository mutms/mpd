package dnsmasq

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/state"
)

// A real /etc/hosts from a cloud-init VM; none of it is mpd's.
const distroHosts = `# Your system has configured 'manage_etc_hosts' as True.
# As a result, if you wish for changes to this file to persist
# then you will need to either
# a.) make changes to the master file in /etc/cloud/templates/hosts.debian.tmpl
# b.) change or remove the value of 'manage_etc_hosts' in
#     /etc/cloud/cloud.cfg or cloud-config from user-data
#
127.0.1.1 mpd-200.local mpd-200
127.0.0.1 localhost

# The following lines are desirable for IPv6 capable hosts
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
`

func block(t *testing.T, records ...Record) string {
	t.Helper()
	return Render("200.mpd.test", records)
}

// Records are plain hosts lines — no dnsmasq config syntax, which a
// hosts file would read as a hostname.
func TestRenderIsExactMatchHostsLines(t *testing.T) {
	body := block(t,
		Record{IP: "10.163.200.1", Names: []string{"200.mpd.test"}},
		Record{IP: "10.163.200.2", Names: []string{"m45.200.mpd.test", "m45"}},
	)
	for _, want := range []string{
		BlockStart + "\n",
		"\n10.163.200.1 200.mpd.test\n",
		"\n10.163.200.2 m45.200.mpd.test m45\n",
		BlockEnd + "\n",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("missing %q:\n%s", want, body)
		}
	}
	for _, forbidden := range []string{"address=", "host-record="} {
		if strings.Contains(body, forbidden) {
			t.Errorf("config syntax %q in a hosts block:\n%s", forbidden, body)
		}
	}
	if !strings.HasSuffix(body, BlockEnd+"\n") {
		t.Errorf("block must end with the fence and one newline:\n%q", body)
	}
}

// Everything outside the fences survives byte for byte, and the block lands
// at the end after one blank line.
func TestSplicePreservesForeignLines(t *testing.T) {
	b := block(t, Record{IP: "10.163.200.1", Names: []string{"200.mpd.test"}})
	got := Splice(distroHosts, b)

	if !strings.HasPrefix(got, distroHosts) {
		t.Errorf("foreign lines changed:\n%s", got)
	}
	if !strings.HasSuffix(got, "ff02::2 ip6-allrouters\n\n"+b) {
		t.Errorf("block not appended after one blank line:\n%s", got)
	}
}

// A second run must be a no-op: the reconcile compares bytes, and any
// drift would mean a reload on every `mpd --vm-start`.
func TestSpliceIsIdempotent(t *testing.T) {
	b := block(t, Record{IP: "10.163.200.1", Names: []string{"200.mpd.test"}})
	once := Splice(distroHosts, b)
	if twice := Splice(once, b); twice != once {
		t.Errorf("second splice changed the file:\n--- once\n%s\n--- twice\n%s", once, twice)
	}
}

// Replacing the block: the old span goes, the foreign lines stay.
func TestSpliceReplacesTheBlock(t *testing.T) {
	old := block(t, Record{IP: "10.163.200.2", Names: []string{"gone.200.mpd.test"}})
	fresh := block(t, Record{IP: "10.163.200.2", Names: []string{"kept.200.mpd.test"}})
	got := Splice(Splice(distroHosts, old), fresh)

	if strings.Contains(got, "gone.200.mpd.test") {
		t.Errorf("stale record survived:\n%s", got)
	}
	if strings.Count(got, BlockStart) != 1 || strings.Count(got, BlockEnd) != 1 {
		t.Errorf("expected exactly one block:\n%s", got)
	}
	if !strings.HasPrefix(got, distroHosts) {
		t.Errorf("foreign lines changed:\n%s", got)
	}
}

// Defensive cases: duplicated block, unterminated block, missing
// trailing newline, empty file.
func TestSpliceDefensiveCases(t *testing.T) {
	b := block(t, Record{IP: "10.163.200.1", Names: []string{"200.mpd.test"}})

	dup := distroHosts + "\n" + b + "\n" + b
	if got := Splice(dup, b); strings.Count(got, BlockStart) != 1 {
		t.Errorf("duplicate block not collapsed:\n%s", got)
	}

	truncated := distroHosts + "\n" + BlockStart + "\n10.163.200.1 200.mpd.test\n"
	if got := Splice(truncated, b); got != Splice(distroHosts, b) {
		t.Errorf("unterminated block not dropped:\n%s", got)
	}

	noNewline := strings.TrimRight(distroHosts, "\n")
	if got := Splice(noNewline, b); !strings.Contains(got, "ip6-allrouters\n\n"+BlockStart) {
		t.Errorf("fence glued to the last line:\n%s", got)
	}

	if got := Splice("", b); got != b {
		t.Errorf("empty file should yield the block alone:\n%q", got)
	}
}

// Incomplete records are skipped, never rendered as half-lines.
func TestRenderSkipsEmptyRecords(t *testing.T) {
	body := block(t, Record{IP: "", Names: []string{"x.200.mpd.test"}}, Record{IP: "10.163.200.1"})
	for _, line := range strings.Split(body, "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		t.Errorf("unexpected record line %q", line)
	}
}

// The LAN file is copied through with names outside mpd.test dropped.
func TestLANRecordsKeepOnlyMpdNames(t *testing.T) {
	path := t.TempDir() + "/lan-hosts"
	if err := os.WriteFile(path,
		[]byte("# comment\n10.1.10.100 forge.mpd.test forge.example.com\n10.1.10.1 router.example.com\n\nbroken\n"),
		0o644); err != nil {
		t.Fatal(err)
	}
	got := lanRecords(path)
	if len(got) != 1 || got[0].IP != "10.1.10.100" || strings.Join(got[0].Names, " ") != "forge.mpd.test" {
		t.Errorf("lanRecords = %+v", got)
	}
	if lanRecords(path+".missing") != nil {
		t.Error("a missing LAN file should publish nothing")
	}
}

// podman fixture: two database containers, one stopped, and one pinned
// to another VM's subnet.
const dbPs = `[
 {"Names":["mpd-db-postgres-18"],"Labels":{"mpd.type":"db","mpd.name":"postgres-18","mpd.ip":"10.163.200.11"},"State":"running"},
 {"Names":["mpd-db-mariadb-11"],"Labels":{"mpd.type":"db","mpd.name":"mariadb-11","mpd.ip":"10.163.200.10"},"State":"exited"},
 {"Names":["mpd-db-stray"],"Labels":{"mpd.type":"db","mpd.name":"stray","mpd.ip":"10.163.150.10"},"State":"running"}
]`

func testManager(t *testing.T) Manager {
	t.Helper()
	n, err := net.New(200)
	if err != nil {
		t.Fatal(err)
	}
	p := podman.NewWith(func(_ context.Context, args []string) (exec.Result, error) {
		if len(args) > 0 && args[0] == "ps" {
			return exec.Result{Stdout: dbPs}, nil
		}
		return exec.Result{Code: 1}, nil
	})
	s := state.NewAt(t.TempDir())
	if err := s.SaveProjects([]state.Project{
		{Name: "m45", URLs: []state.ProjectURL{
			{Kind: "site", URL: "https://m45.200.mpd.test/"},
			{Kind: "behat", URL: "https://behat.m45.200.mpd.test/"},
			{Kind: "mail", URL: "http://mailpit.svc.200.mpd.test:8025/"},
		}},
		{Name: "docs", URLs: []state.ProjectURL{{Kind: "site", URL: "https://docs.200.mpd.test/"}}},
		{Name: "other-vm", URLs: []state.ProjectURL{{Kind: "site", URL: "https://x.150.mpd.test/"}}},
	}); err != nil {
		t.Fatal(err)
	}
	m := New(n, p, s)
	m.lanPath = t.TempDir() + "/no-lan-hosts"
	return m
}

// The fixed records come first: apex, then the VM's own address only
// when it has one.
func TestRecordsFixedSet(t *testing.T) {
	m := testManager(t)

	got := m.Records(context.Background(), nil, "")
	if got[0].IP != "10.163.200.1" || got[0].Names[0] != "200.mpd.test" {
		t.Errorf("apex record wrong: %+v", got[0])
	}
	for _, r := range got {
		if r.Names[0] == "vm.200.mpd.test" {
			t.Error("vm record published for a VM with no address")
		}
	}

	withIP := m.Records(context.Background(), nil, "10.1.10.200")
	if withIP[1].IP != "10.1.10.200" || withIP[1].Names[0] != "vm.200.mpd.test" {
		t.Errorf("vm record missing for a VM with an address: %+v", withIP)
	}
}

// Projects contribute every in-zone host at the project address;
// mail URLs and other VMs' hosts do not. Databases contribute their
// pinned address whether running or not.
func TestRecordsFromState(t *testing.T) {
	m := testManager(t)
	body := Render("200.mpd.test", m.Records(context.Background(),
		[]Record{{IP: "10.163.200.100", Names: []string{"mailpit.svc.200.mpd.test"}}}, ""))

	for _, want := range []string{
		"10.163.200.100 mailpit.svc.200.mpd.test\n",
		"10.163.200.2 behat.m45.200.mpd.test\n",
		"10.163.200.2 docs.200.mpd.test\n",
		"10.163.200.2 m45.200.mpd.test\n",
		"10.163.200.11 postgres-18.db.200.mpd.test\n",
		"10.163.200.10 mariadb-11.db.200.mpd.test\n",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("missing %q:\n%s", want, body)
		}
	}
	for _, forbidden := range []string{"x.150.mpd.test", "stray", "10.163.200.2 mailpit"} {
		if strings.Contains(body, forbidden) {
			t.Errorf("unexpected %q:\n%s", forbidden, body)
		}
	}
	// Sorted within the group: behat.m45 < docs < m45.
	if strings.Index(body, "behat.m45") > strings.Index(body, "docs.200") ||
		strings.Index(body, "docs.200") > strings.Index(body, " m45.200") {
		t.Errorf("project records not sorted:\n%s", body)
	}
}
