package dnsmasq

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mutms/mpd/go/internal/net"
)

func manager(t *testing.T, octet int) (Manager, string) {
	t.Helper()
	n, err := net.New(octet)
	if err != nil {
		t.Fatalf("net.New(%d): %v", octet, err)
	}
	dir := t.TempDir()
	return Manager{dir: filepath.Join(dir, "dns"), n: n}, dir
}

// Records are hosts lines, which match the exact name and nothing else.
//
// This used to be a much more delicate property. As `conf-dir=` fragments
// the apex needed `host-record=` while everything else used `address=`,
// because `address=/domain/ip` matches the domain AND every name beneath
// it — an apex written the ordinary way would have answered for every
// not-yet-created project instead of NXDOMAIN. Hosts files have no
// wildcard form, so the trap is gone rather than avoided.
func TestRecordsAreExactMatchHostsLines(t *testing.T) {
	m, _ := manager(t, 150)
	if _, err := m.EnsureServiceRecords([]ServiceRecord{
		{Host: "150.mpd.test", IP: "10.163.150.1"},
		{Host: "adminer.svc.150.mpd.test", IP: "10.163.150.1"},
	}, ""); err != nil {
		t.Fatal(err)
	}

	body := readRecords(t, m, "services")
	for _, want := range []string{
		"10.163.150.1 150.mpd.test",
		"10.163.150.1 adminer.svc.150.mpd.test",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("missing %q:\n%s", want, body)
		}
	}
	// No dnsmasq config syntax may survive in a file dnsmasq reads as
	// hosts: it would be parsed as a hostname, not as a directive.
	for _, forbidden := range []string{"address=", "host-record="} {
		if strings.Contains(body, forbidden) {
			t.Errorf("config syntax %q in a hosts file:\n%s", forbidden, body)
		}
	}
}

// The VM's own address is published only when it has one — a sandbox VM
// is on DHCP, and a record pointing at nothing is worse than none.
func TestVMRecordOnlyWhenTheVMHasAnAddress(t *testing.T) {
	m, _ := manager(t, 150)
	if _, err := m.EnsureServiceRecords(nil, ""); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(readRecords(t, m, "services"), "vm.150.mpd.test") {
		t.Error("vm record published for a VM with no address")
	}

	if _, err := m.EnsureServiceRecords(nil, "10.211.55.150"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(readRecords(t, m, "services"),
		"10.211.55.150 vm.150.mpd.test") {
		t.Error("vm record missing for a VM with an address")
	}
}

// Writers report "changed" so an unchanged reconcile does not rewrite the
// file. dnsmasq watches the directory: a needless write fires its reload
// and flushes the cache for those names for nothing.
func TestUnchangedWriteReportsNoChange(t *testing.T) {
	m, _ := manager(t, 150)
	records := []ServiceRecord{{Host: "150.mpd.test", IP: "10.163.150.1"}}

	changed, err := m.EnsureServiceRecords(records, "")
	if err != nil || !changed {
		t.Fatalf("first write: changed=%v err=%v, want true/nil", changed, err)
	}
	changed, err = m.EnsureServiceRecords(records, "")
	if err != nil || changed {
		t.Fatalf("second write: changed=%v err=%v, want false/nil", changed, err)
	}
}

// A record left over from a previous VM ID answers for the old zone at an
// address on the old subnet. The entity it describes has to be recreated
// anyway, so the stale file has no value.
func TestPruneRemovesOutOfZoneRecordsOnly(t *testing.T) {
	m, _ := manager(t, 150)
	if err := os.MkdirAll(m.dir, 0o755); err != nil {
		t.Fatal(err)
	}
	write := func(name, body string) {
		if err := os.WriteFile(filepath.Join(m.dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("stale.hosts", "10.163.100.101 stale.100.mpd.test\n")
	write("current.hosts", "10.163.150.101 current.150.mpd.test\n")
	// Rewritten from scratch every reconcile — pruning them would be
	// churn, and one of them legitimately carries the VM's own address.
	write("services.hosts", "10.163.100.1 100.mpd.test\n")
	write("databases.hosts", "10.163.100.20 pg.db.100.mpd.test\n")
	// Not one of mpd's: dnsmasq reads it, but mpd did not write it and
	// must not delete a file it does not own.
	write("notes.txt", "10.163.100.9 whatever.100.mpd.test\n")

	if !m.PruneOutOfZone(io.Discard) {
		t.Fatal("PruneOutOfZone reported no change, want true")
	}
	for name, wantGone := range map[string]bool{
		"stale.hosts":     true,
		"current.hosts":   false,
		"services.hosts":  false,
		"databases.hosts": false,
		"notes.txt":       false,
	} {
		_, err := os.Stat(filepath.Join(m.dir, name))
		if gone := os.IsNotExist(err); gone != wantGone {
			t.Errorf("%s: removed=%v, want %v", name, gone, wantGone)
		}
	}
}

func TestPruneOnACleanTreeChangesNothing(t *testing.T) {
	m, _ := manager(t, 150)
	if err := os.MkdirAll(m.dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(m.dir, "php.hosts"),
		[]byte("10.163.150.100 php.runtime.150.mpd.test\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if m.PruneOutOfZone(io.Discard) {
		t.Error("PruneOutOfZone removed an in-zone record")
	}
}

// A hosts line may carry several names for one address, and every one of
// them has to be checked — a file mixing zones must not survive because
// its first name happened to be in-zone.
func TestRecordHostsReadsEveryNameOnALine(t *testing.T) {
	got := recordHosts("# comment\n10.163.150.100 a.150.mpd.test b.150.mpd.test\n\n10.0.0.1\n")
	want := []string{"a.150.mpd.test", "b.150.mpd.test"}
	if len(got) != len(want) {
		t.Fatalf("recordHosts() = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("recordHosts()[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func readRecords(t *testing.T, m Manager, name string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(m.dir, name+recordSuffix))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}
