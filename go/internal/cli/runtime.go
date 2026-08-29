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
	"github.com/mutms/mpd/go/internal/hooks"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/project"
	"github.com/mutms/mpd/go/internal/runtime"
	"github.com/mutms/mpd/go/internal/state"
)

// RuntimeStop stops the runtime container.
//
// Projects keep their Autostart flag: the user stopped the runtime, not
// the projects, and that distinction is what lets RuntimeStart bring
// them back. See docs/hooks.md §"Resource lifecycle model".
func RuntimeStop(ctx context.Context, out io.Writer, p *podman.Client,
	s state.Store, dns dnsmasq.Manager, o current.Observer) error {

	container := o.RuntimeContainer(runtime.Name)
	if !p.Exists(ctx, container) {
		return fmt.Errorf("The runtime does not exist. Run: mpd --vm-setup")
	}
	if code, err := p.Stop(ctx, container); err != nil || code != 0 {
		return fmt.Errorf("Failed to stop the runtime.")
	}
	if err := saveRuntimeIntent(ctx, "stopped", p, s, container); err != nil {
		return err
	}

	// DNS is untouched. Project names point at the runtime's fixed address,
	// which is still this runtime's: a stopped runtime is a temporary state
	// and the names answer again on the next start.
	Ok(out, "Stopped the runtime.")
	return nil
}

// RuntimeDelete removes the runtime container and everything scoped to
// it.
//
// Projects are NOT deleted, and neither are their DNS names: the runtime
// has a fixed address, so the names keep pointing where the next runtime
// will be, and `mpd delete <project>` remains the explicit way to remove
// a project.
func RuntimeDelete(ctx context.Context, out io.Writer, in io.Reader,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, o current.Observer,
	devUser string, assumeYes bool) error {

	container := o.RuntimeContainer(runtime.Name)
	if !p.Exists(ctx, container) {
		return fmt.Errorf("The runtime does not exist.")
	}

	var names []string
	for _, proj := range s.Projects() {
		names = append(names, proj.Name)
	}
	if len(names) > 0 {
		fmt.Fprintf(out, "The runtime has projects: %s\n", strings.Join(names, ", "))
	}
	// The runtime's home directory accumulates real work. Say exactly
	// what is lost and what survives, because "rebuild the runtime"
	// sounds cheaper than it is.
	fmt.Fprintf(out, "Warning: /home/%s/ contents inside the runtime will be lost.\n", devUser)
	fmt.Fprintln(out, "(config, dotfiles, IDE settings, shell history, manually installed CLIs in ~/.local/bin)")
	fmt.Fprintln(out, "`mpd --runtime-backup` first saves the home directory (config, dotfiles, IDE settings,")
	fmt.Fprintln(out, "history — not caches or binaries); `mpd --runtime-restore` untars it back. Binaries are")
	fmt.Fprintln(out, "not restored — reinstall them (e.g. claude-install).")
	fmt.Fprintln(out, "Preserved across rebuild: your env (/var/lib/mpd/env/ — vm.env, runtime.env), VM-host home overrides (/var/lib/mpd/home/)")

	if !assumeYes && !promptYesNo(out, in,
		"Remove the runtime container?") {
		fmt.Fprintln(out, "Aborted.")
		return nil
	}

	_, _ = p.Stop(ctx, container)
	if code, err := p.Remove(ctx, container); err != nil || code != 0 {
		return fmt.Errorf("Failed to remove the runtime.")
	}
	// `rm` leaves named volumes behind; the disk-backed /tmp volume
	// would otherwise accumulate on every rebuild.
	_, _ = p.VolumeRemove(ctx, runtime.TmpVolume(container))

	if err := s.DeleteRuntime(runtime.Name); err != nil {
		return err
	}
	Ok(out, "Removed the runtime.")
	return nil
}

// saveRuntimeIntent records requested state, reconstructing the entry
// from container labels when no state file exists yet — a runtime
// adopted from an earlier mpd, or one whose state was wiped.
func saveRuntimeIntent(ctx context.Context, requested string,
	p *podman.Client, s state.Store, container string) error {

	if entry, ok := s.Runtime(runtime.Name); ok {
		entry.Requested = requested
		return s.SaveRuntime(entry)
	}
	return s.SaveRuntime(state.Runtime{
		Name:      runtime.Name,
		RuntimeID: runtime.Name,
		IP:        p.Label(ctx, container, "mpd.ip"),
		Requested: requested,
	})
}

// RuntimeStart starts the runtime container and brings its projects
// back.
//
// Three things happen after the container is up, in this order and for
// reasons:
//
//  1. Wait for sshd. The container reports "running" as soon as systemd
//     is up, but services boot asynchronously — without the wait, an
//     immediate `ssh` after this command hits "connection refused" and
//     looks like a failure.
//  2. Start the databases that should autostart: those a `mpd --db-start`
//     marked sticky, plus those an autostart project needs. A database
//     used only by a stopped project stays down.
//  3. Restore projects whose Autostart flag is set. RuntimeStop
//     deliberately left their intent alone, so this is where that
//     intent is honoured again.
func RuntimeStart(ctx context.Context, out io.Writer, p *podman.Client,
	s state.Store, dns dnsmasq.Manager, o current.Observer, n net.Net,
	devUser, uid string) error {

	container := o.RuntimeContainer(runtime.Name)
	if !p.Exists(ctx, container) {
		return fmt.Errorf("The runtime does not exist. Run: mpd --vm-setup")
	}
	if code, err := p.Start(ctx, container); err != nil || code != 0 {
		return fmt.Errorf("Failed to start the runtime.")
	}
	if err := saveRuntimeIntent(ctx, "running", p, s, container); err != nil {
		return err
	}

	runtimeIP := p.Label(ctx, container, "mpd.ip")
	if entry, ok := s.Runtime(runtime.Name); ok && entry.IP != "" {
		runtimeIP = entry.IP
	}
	if runtimeIP != "" {
		if err := waitForSSHD(ctx, out, runtimeIP); err != nil {
			return err
		}
	}
	Ok(out, "Started the runtime.")

	ensureAutostartDatabases(ctx, out, p, s, n, uid)
	// Refresh the cache so databases.json reflects what is now running,
	// while preserving the autostart flags it carries.
	if err := db.RebuildStateCache(ctx, p, s); err != nil {
		fmt.Fprintf(os.Stderr, "Warning: failed to refresh database cache: %v\n", err)
	}
	// restoreRunningProjects ends with the DNS publish, which also picks up
	// any database container created a moment ago.
	return restoreRunningProjects(ctx, out, container, runtimeIP, p, s, dns, n, devUser, uid)
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

// ensureAutostartDatabases starts the databases that should come back on
// their own after a reboot: the ones a `mpd --db-start` marked to
// autostart, plus the ones an autostart project needs. A database used
// only by a stopped project, and never explicitly started, stays down.
//
// Failures warn rather than abort: a runtime that starts without one of
// its databases is still useful, and the project that needs it will say so.
func ensureAutostartDatabases(ctx context.Context, out io.Writer,
	p *podman.Client, s state.Store, n net.Net, uid string) {

	// Distinct engine:version tags to start, deduplicated.
	seen := map[string]bool{}
	add := func(engine, version string) {
		if engine == "" {
			return
		}
		seen[engine+":"+version] = true
	}
	for _, d := range s.Databases() {
		if d.Autostart {
			add(d.Engine, d.Version)
		}
	}
	for _, proj := range s.Projects() {
		if proj.Autostart {
			add(proj.DatabaseEngine, proj.DatabaseVersion)
		}
	}

	for key := range seen {
		ref, err := db.Resolve(ctx, key, p)
		if err == nil {
			err = db.Ensure(ctx, ref, p, n, uid, out)
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "Warning: failed to ensure DB '%s': %v\n", key, err)
		}
	}
}

// restoreRunningProjects re-establishes each running project inside a
// freshly started runtime: cert, type setup script, DNS record.
func restoreRunningProjects(ctx context.Context, out io.Writer, container, runtimeIP string,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, n net.Net, devUser, uid string) error {

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

		// Same refresh-and-check as ProjectStart, in the same order: the
		// cert and DNS record below are composed from proj.URLs, and a
		// rebuilt runtime is exactly when the cached copy is most likely
		// to have gone stale.
		//
		// A project configured for another VM is skipped, not fatal: the
		// other projects are fine, and taking the whole runtime down over
		// one of them helps nobody.
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
			if _, err := project.Exec(ctx, p, container, devUser, "bash", script, proj.Name); err != nil {
				fmt.Fprintf(os.Stderr, "Warning: project-setup for '%s': %v\n", proj.Name, err)
			}
		}
	}
	// Once, after the loop: the URLs refreshed above feed the record set,
	// and one recompute covers every project.
	return PublishDNS(ctx, out, dns, n, s, false)
}

// RuntimeCreate provisions the runtime and everything that hangs off
// it: state, and any projects already assigned to it. (DNS needs no
// step here — runtime.<zone> is a fixed record in the reconciled
// service set.)
//
// The provisioning itself lives in internal/runtime; this is the
// orchestration around it, which is why the two are separate — the
// container work is testable without the DNS and state plumbing.
func RuntimeCreate(ctx context.Context, out io.Writer, p *podman.Client,
	s state.Store, dns dnsmasq.Manager, o current.Observer, n net.Net,
	devUser, uid, home string) error {

	container := o.RuntimeContainer(runtime.Name)

	runtimeIP, err := runtime.Create(ctx, out, runtime.CreateOptions{
		Container: container,
		DevUser:   devUser,
		UID:       uid,
		Home:      home,
		Net:       n,
	}, p)
	if err != nil {
		return err
	}

	// No DNS step: runtime.<zone> has a fixed address, so the record is
	// part of the reconciled service set and published ahead of time.
	if err := s.SaveRuntime(state.Runtime{
		Name: runtime.Name, RuntimeID: runtime.Name, IP: runtimeIP, Requested: "running",
	}); err != nil {
		return err
	}

	// A rebuilt runtime may already have projects assigned to it.
	if err := restoreRunningProjects(ctx, out, container, runtimeIP, p, s, dns, n, devUser, uid); err != nil {
		return err
	}
	if err := waitForSSHD(ctx, out, runtimeIP); err != nil {
		return err
	}

	// A new container has a new home, so setup hooks fire here — the one
	// place every create path goes through. Never fatal: the runtime is up.
	ev := hooks.MpdPostSetup(ctx, container, devUser, p).Only(hooks.AudienceRuntime)
	if err := hooks.Fire(ctx, out, ev, "runtime-create", p); err != nil {
		fmt.Fprintf(out, "  ⚠ %v\n", err)
	}

	fmt.Fprintln(out, "")
	Ok(out, "The runtime is ready.")
	fmt.Fprintf(out, "  IP:   %s\n  SSH:  ssh %s\n", runtimeIP, n.RuntimeAlias())
	return nil
}

// RuntimeUpgrade brings the running runtime forward in place (steps 60 +
// 70 inside it). The runtime is upgraded like a VM, never rebuilt for a
// package change; RuntimeRebuild is for a runtime someone has broken.
func RuntimeUpgrade(ctx context.Context, out io.Writer, p *podman.Client, o current.Observer, devUser string) error {
	container := o.RuntimeContainer(runtime.Name)
	if !p.Running(ctx, container) {
		return fmt.Errorf("The runtime is not running. Run: mpd --vm-start")
	}
	if err := runtime.Upgrade(ctx, out, container, devUser, p); err != nil {
		return err
	}
	Ok(out, "The runtime is up to date.")
	return nil
}

// RuntimeRebuild deletes the runtime container and provisions a fresh
// one, restoring running projects afterwards. The home directory inside
// the container is lost — `mpd --runtime-backup` first preserves the
// pieces worth keeping.
func RuntimeRebuild(ctx context.Context, out io.Writer, in io.Reader,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, o current.Observer,
	n net.Net, devUser, uid, home string, assumeYes bool) error {

	container := o.RuntimeContainer(runtime.Name)
	if p.Exists(ctx, container) {
		if err := RuntimeDelete(ctx, out, in, p, s, dns, o, devUser, assumeYes); err != nil {
			return err
		}
		if p.Exists(ctx, container) {
			// The delete prompt was declined.
			return nil
		}
	}
	return RuntimeCreate(ctx, out, p, s, dns, o, n, devUser, uid, home)
}
