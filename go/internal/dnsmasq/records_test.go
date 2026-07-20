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
	return Manager{dir: filepath.Join(dir, "dnsmasq.d"), n: n}, dir
}

// The zone apex must be a host-record, never `address=`. dnsmasq's
// `address=/domain/ip` matches the domain AND every subdomain, so using
// it for the apex would make every not-yet-created project and runtime
// name resolve to the portal instead of NXDOMAIN.
func TestApexIsAHostRecordNotAWildcard(t *testing.T) {
	m, _ := manager(t, 150)
	if _, err := m.EnsureServiceRecords([]ServiceRecord{
		{Host: "150.mpd.test", IP: "10.163.150.4"},
		{Host: "adminer.service.150.mpd.test", IP: "10.163.150.4"},
	}, ""); err != nil {
		t.Fatal(err)
	}

	body := readConf(t, m, "services.conf")
	if !strings.Contains(body, "host-record=150.mpd.test,10.163.150.4") {
		t.Errorf("apex is not a host-record:\n%s", body)
	}
	if strings.Contains(body, "address=/150.mpd.test/") {
		t.Errorf("apex written as a wildcard address:\n%s", body)
	}
	if !strings.Contains(body, "address=/adminer.service.150.mpd.test/10.163.150.4") {
		t.Errorf("non-apex record missing:\n%s", body)
	}
}

// The VM's own address is published only when it has one — a sandbox VM
// is on DHCP, and a record pointing at nothing is worse than none.
func TestVMRecordOnlyWhenTheVMHasAnAddress(t *testing.T) {
	m, _ := manager(t, 150)
	if _, err := m.EnsureServiceRecords(nil, ""); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(readConf(t, m, "services.conf"), "vm.service") {
		t.Error("vm.service record published for a VM with no address")
	}

	if _, err := m.EnsureServiceRecords(nil, "10.211.55.150"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(readConf(t, m, "services.conf"),
		"host-record=vm.service.150.mpd.test,10.211.55.150") {
		t.Error("vm.service record missing for a VM with an address")
	}
}

// Writers report "changed" so the caller restarts dnsmasq exactly once.
// An unchanged write reporting true would restart the resolver on every
// single command.
func TestUnchangedWriteReportsNoChange(t *testing.T) {
	m, _ := manager(t, 150)
	records := []ServiceRecord{{Host: "portal.service.150.mpd.test", IP: "10.163.150.4"}}

	changed, err := m.EnsureServiceRecords(records, "")
	if err != nil || !changed {
		t.Fatalf("first write: changed=%v err=%v, want true/nil", changed, err)
	}
	changed, err = m.EnsureServiceRecords(records, "")
	if err != nil || changed {
		t.Fatalf("second write: changed=%v err=%v, want false/nil", changed, err)
	}
}

// A fragment left over from a previous VM ID answers for the old zone at
// an address on the old subnet. The entity it describes has to be
// recreated anyway, so the stale file has no value.
func TestPruneRemovesOutOfZoneFragmentsOnly(t *testing.T) {
	m, _ := manager(t, 150)
	if err := os.MkdirAll(m.dir, 0o755); err != nil {
		t.Fatal(err)
	}
	write := func(name, body string) {
		if err := os.WriteFile(filepath.Join(m.dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("stale.conf", "address=/stale.100.mpd.test/10.163.100.101\n")
	write("current.conf", "address=/current.150.mpd.test/10.163.150.101\n")
	// Rewritten from scratch every reconcile — pruning them would be
	// churn, and one of them legitimately carries the VM's own address.
	write("services.conf", "address=/portal.service.100.mpd.test/10.163.100.4\n")
	write("databases.conf", "address=/pg.db.100.mpd.test/10.163.100.20\n")
	// Not a fragment: dnsmasq only reads *.conf.
	write("notes.txt", "address=/whatever.100.mpd.test/10.163.100.9\n")

	if !m.PruneOutOfZone(io.Discard) {
		t.Fatal("PruneOutOfZone reported no change, want true")
	}
	for name, wantGone := range map[string]bool{
		"stale.conf":     true,
		"current.conf":   false,
		"services.conf":  false,
		"databases.conf": false,
		"notes.txt":      false,
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
	if err := os.WriteFile(filepath.Join(m.dir, "php.conf"),
		[]byte("address=/php.runtime.150.mpd.test/10.163.150.100\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if m.PruneOutOfZone(io.Discard) {
		t.Error("PruneOutOfZone removed an in-zone fragment")
	}
}

func readConf(t *testing.T, m Manager, name string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(m.dir, name))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}
