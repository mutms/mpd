package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/db"
	"github.com/mutms/mpd/go/internal/dnsmasq"
	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/hooks"
	"github.com/mutms/mpd/go/internal/project"
	"github.com/mutms/mpd/go/internal/srv"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/vm"
)

// Start brings the VM's mpd environment up: services, then the projects.
// It starts what exists and reports what does not; creating things is
// `--vm-setup`'s job.
func Start(ctx context.Context, out io.Writer, d ProjectDeps, stateDir string) error {
	if _, err := os.Stat(stateDir); err != nil {
		return fmt.Errorf("mpd is not set up yet. Run: mpd --vm-setup")
	}

	// Republish addressing before anything reads it: the VM's ID may
	// have changed since last boot.
	if err := writeVMMeta(ctx, d); err != nil {
		return err
	}

	// systemd owns the VM-hosted services, not the container path below.
	if err := vm.StartUnits(ctx, out); err != nil {
		return err
	}

	// podman-restart.service normally brings extra services back at
	// boot; this reconcile backs that up and repairs revision drift.
	if err := ReconcileServices(ctx, out, d.Podman, d.State, d.Net); err != nil {
		return err
	}

	fmt.Fprintln(out, "\n\033[1m==> DNS resolution\033[0m")
	// Republish the records: a VM rebooted on a different network must
	// not keep answering with its old LAN address. Free when nothing
	// moved — the block is compared before it is written.
	if err := PublishDNS(ctx, out, d.Dnsmasq, d.Net, d.State, false); err != nil {
		return err
	}
	// The resolver may be `active` without answering if it lost the boot
	// race with the bridge; repair it here, where a rebooted VM lands.
	if err := vm.EnsureDnsmasqResolving(ctx, out, d.Net.Gateway(), d.Net.Zone()); err != nil {
		return err
	}
	verifyDNS(ctx, out, d.Net)

	// The project frontdoor is a systemd unit, so systemd has already
	// started it; nudge it only when it is down.
	if !vm.UnitActive(ctx, vm.ProjectCaddyUnitName, false) {
		fmt.Fprintf(out, "\n  Project frontdoor is down — start it with: sudo systemctl start %s\n",
			vm.ProjectCaddyUnitName)
	}

	ensureAutostartDatabases(ctx, out, d.Podman, d.State, d.Net, d.UID)
	if err := db.RebuildStateCache(ctx, d.Podman, d.State); err != nil {
		fmt.Fprintf(os.Stderr, "Warning: failed to refresh database cache: %v\n", err)
	}
	if err := restoreRunningProjects(ctx, out, d.Podman, d.State,
		d.Dnsmasq, d.Net, d.UID); err != nil {
		fmt.Fprintf(out, "  Warning: could not restore projects: %v\n", err)
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

// verifyDNS resolves the fixed names through the VM's own NSS path,
// proving the block landed in /etc/hosts where glibc reads it. Whether
// dnsmasq serves it is EnsureDnsmasqResolving's question. It reports
// rather than fails.
func verifyDNS(ctx context.Context, out io.Writer, n net.Net) {
	if !dnsmasqReachable(ctx) {
		fmt.Fprintf(out, "DNS check: resolver at %s:53 not active within 8s.\n", n.Gateway())
		fmt.Fprintf(out, "  Inspect with: journalctl -u %s\n", vm.DnsmasqUnit)
		return
	}
	// The apex answers at the gateway — the portal is VM infra behind
	// caddy, not a container with an address of its own.
	checks := []struct{ host, want string }{
		{n.Zone(), n.Gateway()},
	}
	// vm.<zone> answers with the VM's own LAN address. Skipped when
	// there is no live address to compare (a DHCP-less sandbox mid-boot).
	if vmIP := vm.PrimaryIP(); vmIP != "" {
		checks = append(checks, struct{ host, want string }{n.VMServiceRecord(), vmIP})
	}

	healthy := true
	for _, c := range checks {
		got := resolveHost(ctx, c.host)
		if got == c.want {
			continue
		}
		healthy = false
		if got == "" {
			fmt.Fprintf(out, "DNS check: no result — nothing answered for %s.\n", c.host)
			fmt.Fprintf(out, "  The name should be in mpd's block in /etc/hosts. Inspect:\n"+
				"    grep -A30 'BEGIN mpd' /etc/hosts\n"+
				"  and repair with: mpd --vm-setup\n")
		} else {
			fmt.Fprintf(out, "DNS check: %s resolved to %s, expected %s\n", c.host, got, c.want)
			fmt.Fprintf(out, "  Something else answers for the name before /etc/hosts. Inspect:\n"+
				"    grep hosts /etc/nsswitch.conf; getent hosts %s\n", c.host)
		}
	}
	if healthy {
		parts := make([]string, len(checks))
		for i, c := range checks {
			parts[i] = c.host + " → " + c.want
		}
		fmt.Fprintf(out, "\033[1;32m✓ DNS: %s\033[0m\n", strings.Join(parts, ", "))
	}

	// Forwarding is a separate question: the names above are served from
	// /etc/hosts and answer even with no upstream at all.
	if vm.ForwardsUpstream(ctx, n.Gateway()) {
		fmt.Fprintf(out, "\033[1;32m✓ DNS: %s forwarded upstream\033[0m\n", vm.UpstreamProbeName)
		return
	}
	fmt.Fprintf(out, "DNS check: the resolver answers for %s but cannot resolve %s.\n",
		n.Zone(), vm.UpstreamProbeName)
	fmt.Fprintln(out, "  Names in the zone are served locally, so they work regardless — but")
	fmt.Fprintln(out, "  containers resolve through this resolver, so apt in a container")
	fmt.Fprintln(out, "  will fail. dnsmasq forwards to the servers in the VM's own")
	fmt.Fprintln(out, "  /etc/resolv.conf. Inspect:")
	fmt.Fprintln(out, "    cat /etc/resolv.conf")
	fmt.Fprintf(out, "    dig @%s %s\n", n.Gateway(), vm.UpstreamProbeName)
	fmt.Fprintf(out, "    journalctl -u %s | tail\n", vm.DnsmasqUnit)
}

func dnsmasqReachable(ctx context.Context) bool {
	for i := 0; i < 16; i++ {
		if vm.UnitActive(ctx, vm.DnsmasqUnit, false) {
			return true
		}
		time.Sleep(500 * time.Millisecond)
	}
	return false
}

func writeVMMeta(ctx context.Context, d ProjectDeps) error {
	return VMMeta(ctx, d.Podman, d.Net, state.Dir)
}

// VMMeta publishes this VM's addressing to both readers: VM-side
// containers via /srv/meta/vm.json, the portal via the state dir's
// vm.json.
func VMMeta(ctx context.Context, p *podman.Client, n net.Net, stateDir string) error {
	// No separate resolver key: it listens on the gateway, and a second
	// key holding the same value is a second thing to keep true.
	meta := map[string]string{
		"vmId":    n.VMID(),
		"zone":    n.Zone(),
		"subnet":  n.Subnet(),
		"gateway": n.Gateway(),
	}
	data, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')

	if err := srv.Write(filepath.Join(srv.Meta, "vm.json"), data, 0o644); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(stateDir, "vm.json"), data, 0o644)
}

// resolveHost uses getent so the answer comes through the same NSS path
// everything else uses.
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

// StopSkipEnv lets a test or an agent exercise the post-stop flow
// without losing its SSH session to a real poweroff.
const StopSkipEnv = "MPD_STOP_DOES_NOT_SHUTDOWN_VM"

// Stop powers the VM off, or fires the pre-stop hooks when systemd is
// the caller. Poweroff makes systemd stop mpd.service, whose ExecStop
// runs this same command; each caller must do only its half or the
// hooks fire twice. INVOCATION_ID, set by systemd, tells them apart.
func Stop(ctx context.Context, out io.Writer, d ProjectDeps, stateDir string) error {
	if _, err := os.Stat(stateDir); err != nil {
		return fmt.Errorf("mpd is not set up yet. Run: mpd --vm-setup")
	}

	if os.Getenv("INVOCATION_ID") != "" {
		// Graceful DB shutdown; without it the next boot finds postgres
		// doing crash recovery. Failures log, never block.
		fmt.Fprintln(out, "\n\033[1m==> Firing pre-stop hooks\033[0m")
		return hooks.Fire(ctx, out, hooks.MpdPreStop(ctx, d.Podman), "stop", d.Podman)
	}

	// Projects marked running stay running in state, so the next start
	// restores them.
	fmt.Fprintln(out, "\n\033[1;33mPowering off VM\033[0m")
	fmt.Fprintln(out, "(your SSH session will drop in a moment; pre-stop hooks fire during shutdown)")

	if os.Getenv(StopSkipEnv) != "" {
		fmt.Fprintf(out, "\n%s is set — skipping VM poweroff.\n", StopSkipEnv)
		return nil
	}
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "systemctl", Args: []string{"poweroff"}, Sudo: true,
	}); err != nil || code != 0 {
		return fmt.Errorf("Failed to power off VM (sudo systemctl poweroff returned %d).", code)
	}
	return nil
}

// Restart reboots the VM. No hooks fire here: the reboot makes systemd
// stop mpd.service, whose ExecStop fires them once.
func Restart(ctx context.Context, out io.Writer, stateDir string) error {
	if _, err := os.Stat(stateDir); err != nil {
		return fmt.Errorf("mpd is not set up yet. Run: mpd --vm-setup")
	}

	fmt.Fprintln(out, "\n\033[1;33mRebooting VM\033[0m")
	fmt.Fprintln(out, "(your SSH session will drop in a moment; mpd auto-starts on boot)")

	if os.Getenv(StopSkipEnv) != "" {
		fmt.Fprintf(out, "\n%s is set — skipping VM reboot.\n", StopSkipEnv)
		return nil
	}
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "systemctl", Args: []string{"reboot"}, Sudo: true,
	}); err != nil || code != 0 {
		return fmt.Errorf("Failed to reboot VM (sudo systemctl reboot returned %d).", code)
	}
	return nil
}

// restoreRunningProjects re-establishes each autostart project: refresh
// its URLs, reissue the cert if the host set moved, run the project
// type's setup script, then publish DNS once for all of them.
func restoreRunningProjects(ctx context.Context, out io.Writer,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, n net.Net, uid string) error {

	var projects []state.Project
	for _, proj := range s.Projects() {
		if proj.Autostart {
			projects = append(projects, proj)
		}
	}
	if len(projects) == 0 {
		return nil
	}

	fmt.Fprintf(out, "\n\033[1m==> Restoring %d project(s)\033[0m\n", len(projects))
	for _, proj := range projects {
		fmt.Fprintf(out, "  Restoring '%s'...\n", proj.Name)

		// Same refresh-and-check as ProjectStart: the cert and DNS record
		// come from proj.URLs, and the cached copy may be stale. A project
		// configured for another VM is skipped, not fatal.
		urls := proj.URLs
		if fresh, ok := project.ReadURLs(proj.Name); ok {
			urls = fresh
		}
		if err := project.CheckConfigured(proj.Name, urls, n); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: skipping '%s': %v\n", proj.Name, err)
			continue
		}
		if !sameURLs(urls, proj.URLs) {
			proj.URLs = urls
			if err := s.UpsertProject(proj); err != nil {
				return err
			}
		}

		if err := project.EnsureCert(ctx, out, proj.Name, proj.URLs, n, p, uid); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: cert for '%s': %v\n", proj.Name, err)
		}

		if cfg, ok := assets.New().ProjectTypeConfig(proj.Type); ok {
			script := assets.TypeScript(cfg.AssetsType, "project-setup.sh")
			if _, err := project.Exec(ctx, "bash", script, proj.Name); err != nil {
				fmt.Fprintf(os.Stderr, "Warning: project-setup for '%s': %v\n", proj.Name, err)
			}
		}
	}
	// One publish after the loop covers every project.
	return PublishDNS(ctx, out, dns, n, s, false)
}
