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

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/hooks"
	"github.com/mutms/mpd/go/internal/srv"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/runtime"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/vm"
)

// Start brings the VM's mpd environment up: services, then any runtime
// that had running projects before the last shutdown.
//
// Ordering: vm.json first, so nothing reads stale addressing; then the
// services.
//
// Deliberately not idempotent-by-creation: `--vm-start` starts what exists
// and reports what does not. Creating things is `--vm-setup`'s job, and
// conflating them would make the daily command unpredictably slow.
func Start(ctx context.Context, out io.Writer, d ProjectDeps, stateDir string) error {
	if _, err := os.Stat(stateDir); err != nil {
		return fmt.Errorf("mpd is not set up yet. Run: mpd --vm-setup")
	}

	// Republish addressing before anything reads it: a VM whose ID
	// changed since last boot must not leave stale URLs behind.
	if err := writeVMMeta(ctx, d); err != nil {
		return err
	}

	// VM-hosted services: systemd owns them, so they are started here
	// rather than through the container path below.
	if err := vm.StartUnits(ctx, out); err != nil {
		return err
	}

	// Autostart extra services: --restart always + podman-restart.service
	// normally brings them back at boot; this reconcile is the belt to
	// that braces, and it also repairs a revision drift.
	if err := ReconcileServices(ctx, out, d.Podman, d.State, d.Net); err != nil {
		return err
	}

	fmt.Fprintln(out, "\n\033[1m==> DNS resolution\033[0m")
	// Republish the record set: the vm.<zone> record carries the VM's LAN
	// address, and a VM that rebooted on a different network (DHCP) must
	// not keep answering with the old one. Free when nothing moved — the
	// block is compared before it is written.
	if err := PublishDNS(ctx, out, d.Dnsmasq, d.Net, d.State, false); err != nil {
		return err
	}
	// The resolver may be `active` without answering if it lost the race
	// with the bridge at boot. This is where a rebooted VM lands, so it is
	// where the repair belongs.
	if err := vm.EnsureDnsmasqResolving(ctx, out, d.Net.Gateway(), d.Net.Zone()); err != nil {
		return err
	}
	verifyDNS(ctx, out, d.Net)

	// The runtime is core infrastructure now — start it whenever it
	// exists, whether or not any project requested running. Failure warns
	// rather than aborts: a VM without its runtime is still worth having
	// started, and --vm-setup is the repair.
	container := d.Observer.RuntimeContainer(runtime.Name)
	switch {
	case !d.Podman.Exists(ctx, container):
		fmt.Fprintln(out, "\n  No runtime container yet — run: mpd --vm-setup")
	case !d.Podman.Running(ctx, container):
		fmt.Fprintln(out, "\n\033[1m==> Restoring the runtime\033[0m")
		if err := RuntimeStart(ctx, out, d.Podman, d.State, d.Dnsmasq,
			d.Observer, d.Net, d.DevUser, d.UID); err != nil {
			fmt.Fprintf(out, "  Warning: could not restore the runtime: %v\n", err)
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

// verifyDNS checks that the VM resolves the fixed names every VM
// publishes — the zone apex (→ gateway) and the runtime (→ its fixed
// address) — through its own NSS path, which is /etc/hosts. That proves
// the block landed where glibc reads it; whether dnsmasq serves it is the
// separate question EnsureDnsmasqResolving answers.
// Reports rather than fails: a VM with broken DNS is still worth having
// started, and the message says what to inspect.
func verifyDNS(ctx context.Context, out io.Writer, n net.Net) {
	if !dnsmasqReachable(ctx) {
		fmt.Fprintf(out, "DNS check: resolver at %s:53 not active within 8s.\n", n.Gateway())
		fmt.Fprintf(out, "  Inspect with: journalctl -u %s\n", vm.DnsmasqUnit)
		return
	}
	// The apex answers at the gateway — the portal is VM infra behind
	// caddy on .1, not a container with an address of its own.
	checks := []struct{ host, want string }{
		{n.Zone(), n.Gateway()},
		{n.RuntimeFQDN(), n.IP(net.HostRuntime)},
	}
	// vm.<zone> answers with the VM's own LAN address. Checked against
	// the live address, which is also what publishing uses — and skipped
	// when there is none to compare (a DHCP-less sandbox mid-boot).
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

	// Forwarding is a separate question from any of the above: every name
	// checked so far is served from /etc/hosts, so they answer even when
	// the resolver has no upstream at all.
	if vm.ForwardsUpstream(ctx, n.Gateway()) {
		fmt.Fprintf(out, "\033[1;32m✓ DNS: %s forwarded upstream\033[0m\n", vm.UpstreamProbeName)
		return
	}
	fmt.Fprintf(out, "DNS check: the resolver answers for %s but cannot resolve %s.\n",
		n.Zone(), vm.UpstreamProbeName)
	fmt.Fprintln(out, "  Names in the zone are served locally, so they work regardless — but")
	fmt.Fprintln(out, "  containers resolve through this resolver, so apt inside the runtime")
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

// VMMeta publishes this VM's addressing to both places that need it.
//
// Two audiences, same bytes: runtime containers see /srv/meta/vm.json
// via the data volume; the portal reads vm.json from the state dir.
// Neither can read /var/lib/mpd/conf/, which holds the CA key and is
// deliberately never mounted into a container.
func VMMeta(ctx context.Context, p *podman.Client, n net.Net, stateDir string) error {
	// No separate resolver address: it listens on the gateway, and a
	// second key holding the same value is a second thing to keep true.
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

// StopSkipEnv lets a test or an agent exercise the post-stop flow
// without losing its SSH session to a real poweroff.
const StopSkipEnv = "MPD_STOP_DOES_NOT_SHUTDOWN_VM"

// Stop powers the VM off — or, when systemd is the caller, fires the
// pre-stop hooks.
//
// One command, two callers needing opposite halves of the work:
//
//   - a human typing `mpd --vm-stop` powers off, and must NOT fire hooks,
//     because powering off makes systemd stop mpd.service, whose
//     ExecStop runs this same command again;
//   - systemd's ExecStop fires the hooks, and must NOT power off — that
//     is already happening.
//
// Doing both in both places fired mpd-pre-stop twice, the second time
// against databases already shutting down. systemd sets INVOCATION_ID
// for every process it runs as a unit, so the callers tell themselves
// apart with no unit change and nothing to migrate.
func Stop(ctx context.Context, out io.Writer, d ProjectDeps, stateDir string) error {
	if _, err := os.Stat(stateDir); err != nil {
		return fmt.Errorf("mpd is not set up yet. Run: mpd --vm-setup")
	}

	if os.Getenv("INVOCATION_ID") != "" {
		// Graceful DB shutdown. Without it the next boot finds postgres
		// doing crash recovery. Failures are logged, never blocking.
		fmt.Fprintln(out, "\n\033[1m==> Firing pre-stop hooks\033[0m")
		return hooks.Fire(ctx, out, hooks.MpdPreStop(ctx, d.Podman), "stop", d.Podman)
	}

	// Project intent is preserved across the power cycle: projects marked
	// running stay running in state, so the next start restores them.
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

// Restart reboots the VM.
//
// No hooks fired here on purpose: the reboot makes systemd stop
// mpd.service, and its ExecStop fires them once. Firing here as well
// would double up, which is the defect Stop above exists to avoid.
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
