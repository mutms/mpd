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

// serviceFilter selects the extra service containers. Every listing must
// use this same filter so they all see the same set.
const serviceFilter = "label=com.docker.compose.project=mpd-service"

// ListServices renders the `list services` table of optional extra
// service containers. It joins persisted intent against one `podman ps`
// snapshot; per-service inspects would race a restarting service.
func ListServices(ctx context.Context, out io.Writer, n net.Net, p *podman.Client, s state.Store) {
	live := map[string]string{}
	for _, item := range p.Ps(ctx, serviceFilter) {
		if name := item.Label("mpd.name"); name != "" {
			live[name] = item.State
		}
	}
	installed := map[string]bool{}
	for _, entry := range s.Services() {
		installed[entry.Name] = true
	}

	fmt.Fprintln(out, Col("SERVICE", colService)+Col("STATUS", colStatus)+Col("IP", colIP)+"ACCESS")
	fmt.Fprintln(out, Rule(92))

	for _, d := range service.All() {
		status := "not installed"
		access := "mpd --service-start=" + d.Name
		switch {
		case live[d.Name] == "running":
			status = StatusRunning
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

// ListInfra renders the `list infra` table: the VM's systemd pieces
// (dnsmasq, portal, project frontdoor). unitActive is injected so tests
// need no systemd.
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
		case "projects":
			access = fmt.Sprintf("project HTTPS (%s:443)", n.IP(net.HostProjects))
		}
		fmt.Fprintln(out, Col(inf.Name, colService)+
			StatusLabel(status, colStatus)+
			access)
	}
}
