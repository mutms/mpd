package service

import (
	"context"
	"io"

	"github.com/mutms/mpd/go/internal/dnsmasq"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/ui"
	"github.com/mutms/mpd/go/internal/vm"
)

// ReconcileDNSRecords rewrites the record files that mpd derives rather
// than writes on demand: the service names, and the database names read
// back from live containers. Stale out-of-zone records are pruned first.
//
// The resolver itself is not touched. It runs on the VM (see
// vm.ConfigureDnsmasq) and watches its hosts directory, so a changed
// record file is already live by the time this returns — there is nothing
// to signal, restart or wait for.
//
// verbose is off on the daily path, where "nothing moved" is the normal
// answer and saying so on every `--vm-start` is noise.
func ReconcileDNSRecords(ctx context.Context, out io.Writer, m dnsmasq.Manager,
	n net.Net, vmIP string, verbose bool) error {

	stale := m.PruneOutOfZone(out)

	records := make([]dnsmasq.ServiceRecord, 0, len(DNSRecords(n)))
	for _, r := range DNSRecords(n) {
		records = append(records, dnsmasq.ServiceRecord{Host: r.Host, IP: r.IP})
	}
	services, err := m.EnsureServiceRecords(records, vmIP)
	if err != nil {
		return err
	}
	databases, err := m.EnsureDatabaseRecords(ctx)
	if err != nil {
		return err
	}
	// Names for LAN machines that are not VMs, pushed in from the
	// workstation. Publishing them here is what lets a container resolve
	// `forge.mpd.test` — containers use this resolver and have no
	// /etc/hosts of their own.
	lan, err := m.EnsureLANRecords(vm.LanHostsPath)
	if err != nil {
		return err
	}

	if !verbose {
		return nil
	}
	switch {
	case databases:
		ui.OK(out, "Service and database DNS records published.")
	case services || stale:
		ui.OK(out, "Service DNS records published.")
	case lan:
		ui.OK(out, "LAN service DNS records published.")
	default:
		ui.OK(out, "DNS records already current.")
	}
	return nil
}
