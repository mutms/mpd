package cli

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/service"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/vm"
)

// serviceFilter selects the extra service containers. Note this is a
// compose label rather than mpd.managed — kept as-is so this and the
// other listings see exactly the same set.
const serviceFilter = "label=com.docker.compose.project=mpd-service"

// ListServices renders the `list services` table — the OPTIONAL extra
// service containers, with their persisted intent joined against a
// single `podman ps` snapshot (per-service inspects race a service
// restarting mid-listing).
func ListServices(ctx context.Context, out io.Writer, n net.Net, p *podman.Client, s state.Store) {
	live := map[string]string{}
	for _, item := range p.Ps(ctx, serviceFilter) {
		if name := item.Label("mpd.name"); name != "" {
			live[name] = item.State
		}
	}
	intent := map[string]bool{}
	installed := map[string]bool{}
	for _, entry := range s.Services() {
		intent[entry.Name] = entry.Enabled
		installed[entry.Name] = true
	}

	fmt.Fprintln(out, Col("SERVICE", colService)+Col("STATUS", colStatus)+Col("IP", colIP)+"ACCESS")
	fmt.Fprintln(out, Rule(92))

	for _, d := range service.All() {
		status := "not installed"
		access := "mpd --service-enable=" + d.Name
		switch {
		case live[d.Name] == "running":
			status = StatusRunning
			access = d.AccessHint(n)
		case installed[d.Name] && !intent[d.Name]:
			status = "disabled"
			access = d.AccessHint(n)
		case installed[d.Name]:
			status = StatusStopped
			access = d.AccessHint(n)
		}
		fmt.Fprintln(out, Col(d.Name, colService)+
			StatusLabel(status, colStatus)+
			Col(d.IP(n), colIP)+
			access)
	}
}

// ListInfra renders the `list infra` table — the VM-integral systemd
// pieces (dnsmasq, portal), always on, distinct from the optional
// services. unitActive is passed in so the listing stays testable
// without a systemd on the other end.
func ListInfra(ctx context.Context, out io.Writer, n net.Net,
	unitActive func(context.Context, string, bool) bool) {

	fmt.Fprintln(out, Col("INFRA", colService)+Col("STATUS", colStatus)+"ACCESS")
	fmt.Fprintln(out, Rule(72))

	for _, inf := range vm.InfraServices() {
		status := StatusStopped
		if unitActive != nil && unitActive(ctx, inf.Unit, inf.UnitUser) {
			status = StatusRunning
		}
		access := ""
		switch inf.Name {
		case "dnsmasq":
			access = fmt.Sprintf("DNS resolver (%s:53)", n.Gateway())
		case "portal":
			access = fmt.Sprintf("https://%s/", n.Zone())
		}
		fmt.Fprintln(out, Col(inf.Name, colService)+
			StatusLabel(status, colStatus)+
			access)
	}
}
