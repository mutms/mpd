package cli

import (
	"context"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/service"
)

// serviceFilter selects the always-on service containers. Note this is a
// compose label rather than mpd.managed — kept as-is so this and the
// other listings
// listings see exactly the same set.
const serviceFilter = "label=com.docker.compose.project=mpd-service"

// ListServices renders the `list services` table.
//
// One `podman ps` snapshot is taken and indexed by container name, rather
// than inspecting each service in turn: per-service inspects race against
// a service restarting mid-listing and can report a mix of before and
// after.
// unitActive reports whether a systemd-backed service is running. Passed
// in rather than called directly so the listing stays testable without a
// systemd on the other end.
func ListServices(ctx context.Context, out io.Writer, n net.Net, p *podman.Client,
	unitActive func(context.Context, string, bool) bool) {
	stateByContainer := map[string]string{}
	for _, item := range p.Ps(ctx, serviceFilter) {
		if name := item.Name(); name != "" {
			stateByContainer[name] = item.State
		}
	}

	fmt.Fprintln(out, Col("SERVICE", colService)+Col("STATUS", colStatus)+Col("IP", colIP)+"ACCESS")
	fmt.Fprintln(out, Rule(92))

	for _, d := range sortedByIP(n) {
		status := StatusNotCreated
		if d.Unit != "" {
			// VM-hosted: systemd owns it, podman has never heard of it.
			status = StatusStopped
			if unitActive != nil && unitActive(ctx, d.Unit, d.UnitUser) {
				status = StatusRunning
			}
		} else if state, ok := stateByContainer[d.Container]; ok {
			status = StatusStopped
			if state == "running" {
				status = StatusRunning
			}
		}
		fmt.Fprintln(out, Col(d.Name, colService)+
			StatusLabel(status, colStatus)+
			Col(d.IP(n), colIP)+
			d.AccessHint(n))
	}
}

// sortedByIP orders services by address, falling back to name. Sorting on
// the numeric octets rather than the string keeps .30 before .100, which
// a lexicographic sort would get wrong once DB containers are listed.
func sortedByIP(n net.Net) []service.Descriptor {
	all := service.All()
	sort.SliceStable(all, func(i, j int) bool {
		li, lj := ipSortKey(all[i].IP(n)), ipSortKey(all[j].IP(n))
		for k := 0; k < len(li) && k < len(lj); k++ {
			if li[k] != lj[k] {
				return li[k] < lj[k]
			}
		}
		if len(li) != len(lj) {
			return len(li) < len(lj)
		}
		return all[i].Name < all[j].Name
	})
	return all
}

func ipSortKey(ip string) []int {
	parts := strings.Split(ip, ".")
	key := make([]int, 0, len(parts))
	for _, p := range parts {
		v, err := strconv.Atoi(p)
		if err != nil {
			continue
		}
		key = append(key, v)
	}
	return key
}
