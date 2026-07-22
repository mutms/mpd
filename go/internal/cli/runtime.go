package cli

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/current"
	"github.com/mutms/mpd/go/internal/db"
	"github.com/mutms/mpd/go/internal/dnsmasq"
	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/project"
	"github.com/mutms/mpd/go/internal/runtime"
	"github.com/mutms/mpd/go/internal/sidecar"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
)

// RuntimeStop stops a runtime pod.
//
// Projects on it keep requested=running: the user stopped the runtime,
// not the projects, and that distinction is what lets `--runtime-start`
// bring them back. Their dnsmasq records are dropped though — a URL that
// resolves to a stopped runtime gives a confusing connection error
// instead of a clean NXDOMAIN. See docs/HOOKS.md §"Resource lifecycle
// model".
func RuntimeStop(ctx context.Context, out io.Writer, name string, p *podman.Client,
	s state.Store, dns dnsmasq.Manager, o current.Observer) error {

	container := o.RuntimeContainer(name)
	if !p.Exists(ctx, container) {
		return fmt.Errorf("Runtime '%s' does not exist.", name)
	}
	if code, err := p.PodStop(ctx, podName(o, name)); err != nil || code != 0 {
		return fmt.Errorf("Failed to stop runtime '%s'.", name)
	}
	if err := saveRuntimeIntent(ctx, name, "stopped", p, s, container); err != nil {
		return err
	}

	for _, proj := range s.Projects() {
		if proj.RuntimeName == name && proj.Requested == "running" {
			if _, err := dns.RemoveRecord(proj.Name); err != nil {
				return err
			}
		}
	}
	Ok(out, "Stopped runtime '%s'.", name)
	return nil
}

// RuntimeDelete removes a runtime pod and everything scoped to it.
//
// Projects are NOT deleted — only their DNS records, which would
// otherwise resolve to a runtime that no longer exists. The project
// records survive so `mpd <project> delete` (or a later `--gc`) remains
// the explicit way to remove them.
func RuntimeDelete(ctx context.Context, out io.Writer, in io.Reader, name string,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, o current.Observer,
	devUser string, assumeYes bool) error {

	container := o.RuntimeContainer(name)
	if !p.Exists(ctx, container) {
		return fmt.Errorf("Runtime '%s' does not exist.", name)
	}

	var names []string
	for _, proj := range s.Projects() {
		if proj.RuntimeName == name {
			names = append(names, proj.Name)
		}
	}
	if len(names) > 0 {
		fmt.Fprintf(out, "Runtime '%s' has projects: %s\n", name, strings.Join(names, ", "))
	}
	// Runtimes are pets: the home directory accumulates real work. Say
	// exactly what is lost and what survives, because "delete the
	// runtime" sounds cheaper than it is.
	fmt.Fprintf(out, "Warning: /home/%s/ contents inside the runtime will be lost.\n", devUser)
	fmt.Fprintln(out, "(IDE settings, shell history, manually installed CLIs in ~/.local/bin)")
	fmt.Fprintln(out, "Preserved across recreate: mpd-vm.env (/var/lib/mpd/env/), VM-host skel (/var/lib/mpd/skel/)")

	if !assumeYes && !promptYesNo(out, in,
		fmt.Sprintf("Remove runtime '%s' and all its containers?", name)) {
		fmt.Fprintln(out, "Aborted.")
		return nil
	}

	pod := podName(o, name)
	_, _ = p.PodStop(ctx, pod)
	if code, err := p.PodRemove(ctx, pod); err != nil || code != 0 {
		return fmt.Errorf("Failed to remove runtime '%s'.", name)
	}
	// `pod rm` leaves named volumes behind; the disk-backed /tmp volume
	// would otherwise accumulate on every recreate.
	_, _ = p.VolumeRemove(ctx, pod+"-tmp")

	// Runtime-level records, plus the pseudo-project holding sidecar URLs.
	if _, err := dns.RemoveRecord(name); err != nil {
		return err
	}
	if _, err := dns.RemoveRecord("_runtime-" + name); err != nil {
		return err
	}
	if err := srv.Remove(ctx, srv.MetaDir("_runtime-"+name)); err != nil {
		return err
	}
	// Orphaned projects' records: their URLs would resolve to a runtime
	// that is gone.
	for _, projName := range names {
		if _, err := dns.RemoveRecord(projName); err != nil {
			return err
		}
	}
	if err := s.DeleteRuntime(name); err != nil {
		return err
	}
	Ok(out, "Removed runtime '%s'.", name)
	return nil
}

// podName is the pod for a runtime: mpd-<vmid>-<runtime>. The main
// container is that plus "-main", which is what Observer already knows.
func podName(o current.Observer, runtime string) string {
	return strings.TrimSuffix(o.RuntimeContainer(runtime), "-main")
}

// saveRuntimeIntent records requested state, reconstructing the entry
// from container labels when no state file exists yet — a runtime
// adopted from an earlier mpd, or one whose state was wiped.
func saveRuntimeIntent(ctx context.Context, name, requested string,
	p *podman.Client, s state.Store, container string) error {

	if entry, ok := s.Runtime(name); ok {
		entry.Requested = requested
		return s.SaveRuntime(entry)
	}
	runtimeID := p.Label(ctx, container, "mpd.runtime")
	if runtimeID == "" {
		runtimeID = name
	}
	return s.SaveRuntime(state.Runtime{
		Name:      name,
		RuntimeID: runtimeID,
		IP:        p.Label(ctx, container, "mpd.ip"),
		Requested: requested,
	})
}

// RuntimeStart starts a runtime pod and brings its projects back.
//
// Three things happen after the pod is up, in this order and for
// reasons:
//
//  1. Wait for sshd. The pod reports "running" as soon as systemd is up,
//     but services boot asynchronously — without the wait, an immediate
//     `ssh` after this command hits "connection refused" and looks like
//     a failure.
//  2. Pre-warm every database any project here might want, running or
//     stopped, so a later `mpd start <project>` never waits on a cold
//     engine.
//  3. Restore projects whose requested state is running. `--runtime-stop`
//     deliberately left their intent alone, so this is where that
//     intent is honoured again.
func RuntimeStart(ctx context.Context, out io.Writer, name string, p *podman.Client,
	s state.Store, dns dnsmasq.Manager, o current.Observer, n net.Net,
	devUser, uid string) error {

	container := o.RuntimeContainer(name)
	if !p.Exists(ctx, container) {
		return fmt.Errorf("Runtime '%s' does not exist.", name)
	}
	if code, err := p.PodStart(ctx, podName(o, name)); err != nil || code != 0 {
		return fmt.Errorf("Failed to start runtime '%s'.", name)
	}
	if err := saveRuntimeIntent(ctx, name, "running", p, s, container); err != nil {
		return err
	}

	runtimeIP := p.Label(ctx, container, "mpd.ip")
	if entry, ok := s.Runtime(name); ok && entry.IP != "" {
		runtimeIP = entry.IP
	}
	if runtimeIP != "" {
		if err := waitForSSHD(ctx, out, runtimeIP); err != nil {
			return err
		}
	}
	Ok(out, "Started runtime '%s'.", name)

	ensureProjectDatabases(ctx, out, name, p, s, n, uid)
	// Same reason as in ProjectStart: a DB container created a moment ago
	// has an address nothing has published yet.
	if _, err := dns.EnsureDatabaseRecords(ctx); err != nil {
		return err
	}
	return restoreRunningProjects(ctx, out, name, container, runtimeIP, p, s, dns, n, devUser, uid)
}

// waitForSSHD blocks until sshd answers on the runtime's address.
//
// Probed with bash's /dev/tcp rather than a TCP dial from Go: the check
// must run in the same network namespace view mpd itself has, and the
// banner check rejects a socket that accepts but is not sshd.
func waitForSSHD(ctx context.Context, out io.Writer, ip string) error {
	script := fmt.Sprintf(
		`exec 3<>/dev/tcp/%s/22 2>/dev/null && IFS= read -t 2 -u 3 banner && [[ "$banner" == SSH-* ]]`, ip)
	probe := func() bool {
		res, err := exec.Capture(ctx, exec.Cmd{Name: "bash", Args: []string{"-c", script}})
		return err == nil && res.Code == 0
	}
	if probe() {
		return nil
	}
	fmt.Fprintf(out, "  Waiting for sshd to bind on %s:22…\n", ip)
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(500 * time.Millisecond)
		if probe() {
			return nil
		}
	}
	fmt.Fprintf(out, "  Warning: sshd did not bind on %s:22 within 30s.\n", ip)
	return nil
}

// ensureProjectDatabases starts each distinct engine:version any project
// on this runtime uses. Failures warn rather than abort: a runtime that
// starts without one of its databases is still useful, and the project
// that needs it will say so.
func ensureProjectDatabases(ctx context.Context, out io.Writer, runtime string,
	p *podman.Client, s state.Store, n net.Net, uid string) {

	seen := map[string]bool{}
	for _, proj := range s.Projects() {
		if proj.RuntimeName != runtime || proj.DatabaseEngine == "" {
			continue
		}
		key := proj.DatabaseEngine + ":" + proj.DatabaseVersion
		if seen[key] {
			continue
		}
		seen[key] = true
		ref, err := db.Resolve(ctx, key, p)
		if err == nil {
			err = db.Ensure(ctx, ref, p, n, uid, out)
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "Warning: failed to ensure DB '%s' for runtime '%s': %v\n",
				key, runtime, err)
		}
	}
}

// restoreRunningProjects re-establishes each running project inside a
// freshly started runtime: cert, type setup script, DNS record.
func restoreRunningProjects(ctx context.Context, out io.Writer, runtime, container, runtimeIP string,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, n net.Net, devUser, uid string) error {

	var projects []state.Project
	for _, proj := range s.Projects() {
		if proj.RuntimeName == runtime && proj.Requested == "running" {
			projects = append(projects, proj)
		}
	}
	if len(projects) == 0 {
		return nil
	}

	fmt.Fprintf(out, "\n\033[1m==> Restoring %d project(s) in '%s'\033[0m\n", len(projects), runtime)
	for _, proj := range projects {
		fmt.Fprintf(out, "  Restoring '%s'...\n", proj.Name)

		if err := project.EnsureCert(ctx, out, proj.Name, proj.URLs, n, p, uid); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: cert for '%s': %v\n", proj.Name, err)
		}

		if cfg, ok := assets.New().ProjectTypeConfig(proj.Type); ok {
			script := fmt.Sprintf("/opt/mpd/assets/runtimes/%s/project_types/%s/project-setup.sh",
				cfg.AssetsRuntime, cfg.AssetsType)
			if _, err := project.Exec(ctx, p, container, devUser, "bash", script, proj.Name); err != nil {
				fmt.Fprintf(os.Stderr, "Warning: project-setup for '%s': %v\n", proj.Name, err)
			}
		}

		if body, ok := project.DNSRecords(proj.Name, proj.URLs, runtimeIP, n); ok {
			if _, err := dns.WriteRecord(proj.Name, body); err != nil {
				return err
			}
		}
	}
	return nil
}

// RuntimeCreate provisions a new runtime and everything that hangs off
// it: DNS record, state, sidecars, and any projects already assigned to
// it.
//
// The provisioning itself lives in internal/runtime; this is the
// orchestration around it, which is why the two are separate — the
// container work is testable without the DNS and state plumbing.
func RuntimeCreate(ctx context.Context, out io.Writer, name string, p *podman.Client,
	s state.Store, dns dnsmasq.Manager, o current.Observer, n net.Net,
	a assets.Tree, devUser, uid, home string) error {

	container := o.RuntimeContainer(name)
	pod := podName(o, name)

	runtimeIP, err := runtime.Create(ctx, out, runtime.CreateOptions{
		Name:      name,
		Pod:       pod,
		Container: container,
		DevUser:   devUser,
		UID:       uid,
		Home:      home,
		Net:       n,
		Assets:    a,
	}, p)
	if err != nil {
		return err
	}

	fmt.Fprintln(out, "\n\033[1m==> Publishing DNS record\033[0m")
	if _, err := dns.WriteRecord(name, dnsmasq.Line(n.Runtime(name), runtimeIP)+"\n"); err != nil {
		return err
	}

	if err := s.SaveRuntime(state.Runtime{
		Name: name, RuntimeID: name, IP: runtimeIP, Requested: "running",
	}); err != nil {
		return err
	}

	// Sidecars: runtime defaults now, URL-derived ones later. At create
	// time no project has published URLs yet, so selenium and friends
	// cannot be known — the project verbs re-reconcile when they land.
	fmt.Fprintln(out, "\n\033[1m==> Attaching runtime sidecars\033[0m")
	if err := sidecar.Reconcile(ctx, out, pod, sidecar.Desired(name, s, a), p); err != nil {
		return err
	}

	// A recreated runtime may already have projects assigned to it.
	if err := restoreRunningProjects(ctx, out, name, container, runtimeIP, p, s, dns, n, devUser, uid); err != nil {
		return err
	}
	if err := waitForSSHD(ctx, out, runtimeIP); err != nil {
		return err
	}

	fmt.Fprintln(out, "")
	Ok(out, "Runtime '%s' is ready.", name)
	fmt.Fprintf(out, "  IP:   %s\n  SSH:  ssh %s\n", runtimeIP, n.Runtime(name))
	return nil
}
