package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/mutms/mpd/go/internal/exec"

	"github.com/mutms/mpd/go/internal/dnsmasq"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/service"
	"github.com/mutms/mpd/go/internal/state"
)

// Start brings the VM's mpd environment up: services, then any runtime
// that had running projects before the last shutdown.
//
// Ordering: fileaccess first, because it is the data-volume exec target
// every later step uses; then vm.json, so nothing reads stale addressing;
// then the rest.
//
// Deliberately not idempotent-by-creation: `--start` starts what exists
// and reports what does not. Creating things is `--setup`'s job, and
// conflating them would make the daily command unpredictably slow.
func Start(ctx context.Context, out io.Writer, d ProjectDeps, stateDir string) error {
	if _, err := os.Stat(stateDir); err != nil {
		return fmt.Errorf("mpd is not set up yet. Run: mpd --setup")
	}

	fileaccess, _ := service.Find("fileaccess")
	if err := service.Start(ctx, out, fileaccess, d.Net, d.Podman); err != nil {
		return err
	}

	// Republish addressing before anything reads it: a VM whose ID
	// changed since last boot must not leave stale URLs behind.
	if err := writeVMMeta(ctx, d); err != nil {
		return err
	}

	for _, name := range []string{"dnsmasq", "portal", "adminer"} {
		svc, ok := service.Find(name)
		if !ok {
			continue
		}
		if err := service.Start(ctx, out, svc, d.Net, d.Podman); err != nil {
			return err
		}
	}

	fmt.Fprintln(out, "\n\033[1m==> DNS resolution\033[0m")
	verifyDNS(ctx, out, d)

	// Restore runtimes that had running projects. Failure warns rather
	// than aborts: one broken runtime should not stop the others coming
	// back.
	var names []string
	seen := map[string]bool{}
	for _, p := range d.State.Projects() {
		if p.Requested == "running" && p.RuntimeName != "" && !seen[p.RuntimeName] {
			seen[p.RuntimeName] = true
			names = append(names, p.RuntimeName)
		}
	}
	sort.Strings(names)
	for _, name := range names {
		container := d.Observer.RuntimeContainer(name)
		if !d.Podman.Exists(ctx, container) || d.Podman.Running(ctx, container) {
			continue
		}
		fmt.Fprintf(out, "\n\033[1m==> Restoring runtime '%s'\033[0m\n", name)
		if err := RuntimeStart(ctx, out, name, d.Podman, d.State, d.Dnsmasq,
			d.Observer, d.Net, d.DevUser, d.UID); err != nil {
			fmt.Fprintf(out, "  Warning: could not restore runtime '%s': %v\n", name, err)
		}
	}

	if err := d.Observer.Refresh(ctx, stateDir, d.State, time.Now()); err != nil {
		return err
	}

	fmt.Fprintf(out, "\n\033[1;32m✓ mpd started.\033[0m\n\n")
	fmt.Fprintf(out, "  https://%s/\n", d.Net.Zone())
	fmt.Fprintln(out, "  mpd list              show all projects")
	fmt.Fprintln(out, "  mpd start <project>   start a project")
	return nil
}

// verifyDNS checks that the VM's own resolver answers for the zone apex
// through dnsmasq. Reports rather than fails: a VM with broken DNS is
// still worth having started, and the message says what to inspect.
func verifyDNS(ctx context.Context, out io.Writer, d ProjectDeps) {
	dnsIP := d.Net.IP(net.HostDnsmasq)
	if !dnsmasqReachable(ctx, d.Podman) {
		fmt.Fprintf(out, "DNS check: dnsmasq at %s:53 not reachable within 8s.\n", dnsIP)
		fmt.Fprintf(out, "  Inspect with: sudo podman logs %s\n", dnsmasq.Container)
		return
	}
	got := resolveHost(ctx, d.Net.Zone())
	if got == d.Net.IP(net.HostPortal) {
		fmt.Fprintf(out, "\033[1;32m✓ DNS: %s → %s\033[0m\n", d.Net.Zone(), got)
		return
	}
	if got == "" {
		fmt.Fprintln(out, "DNS check: no result — system resolver not pointing at dnsmasq")
	} else {
		fmt.Fprintf(out, "DNS check: got %s, expected %s\n", got, d.Net.IP(net.HostPortal))
	}
	fmt.Fprintf(out, "  Verify: resolvectl status; getent hosts %s\n", d.Net.Zone())
}

func dnsmasqReachable(ctx context.Context, p *podman.Client) bool {
	for i := 0; i < 16; i++ {
		if p.Running(ctx, dnsmasq.Container) {
			return true
		}
		time.Sleep(500 * time.Millisecond)
	}
	return false
}

func writeVMMeta(ctx context.Context, d ProjectDeps) error {
	return VMMeta(ctx, d.Podman, d.Net, state.Dir)
}

// VMMeta publishes this VM's addressing to both places that need it.
//
// Two audiences in different mount namespaces, same bytes:
// runtime containers see /srv/meta/vm.json via the data volume; the
// portal sees /mpd-state/vm.json via the state dir. Neither can read
// /var/lib/mpd/conf/platform.env, which holds the CA key and is
// deliberately never mounted into a container.
func VMMeta(ctx context.Context, p *podman.Client, n net.Net, stateDir string) error {
	meta := map[string]string{
		"vmId":      n.VMID(),
		"zone":      n.Zone(),
		"subnet":    n.Subnet(),
		"gateway":   n.Gateway(),
		"dnsmasqIp": n.IP(net.HostDnsmasq),
	}
	data, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')

	if err := p.VolumeWrite(ctx, "", "mkdir -p /srv/meta && cat > /srv/meta/vm.json", data); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(stateDir, "vm.json"), data, 0o644)
}

// resolveHost asks the VM's own resolver for a name, via getent so the
// answer comes through the same NSS path everything else uses.
func resolveHost(ctx context.Context, host string) string {
	res, err := exec.Capture(ctx, exec.Cmd{
		Name: "bash",
		Args: []string{"-c", fmt.Sprintf("getent hosts %s 2>/dev/null | awk '{print $1}'", host)},
	})
	if err != nil || res.Code != 0 {
		return ""
	}
	return strings.TrimSpace(res.Stdout)
}
