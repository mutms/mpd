package cli

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"github.com/mutms/mpd/go/internal/db"
	"github.com/mutms/mpd/go/internal/dnsmasq"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
)

// Ok prints a success line. ANSI is unconditional, matching the listing
// helpers; the difftest compares this output byte for byte.
func Ok(out io.Writer, format string, args ...any) {
	fmt.Fprintf(out, "\033[1;32m✓ "+format+"\033[0m\n", args...)
}

// DBStart starts a stopped DB container.
func DBStart(ctx context.Context, out io.Writer, input string,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, n net.Net) error {

	ref, err := db.Resolve(ctx, input, p)
	if err != nil {
		return err
	}
	if !p.Exists(ctx, ref.Container) {
		return fmt.Errorf("DB container '%s' does not exist. Use --db-create to create it.", ref.Container)
	}
	if p.Running(ctx, ref.Container) {
		fmt.Fprintf(out, "%s is already running.\n", ref.Container)
		return syncDatabaseState(ctx, p, s, dns, n, ref.ID, true)
	}
	if code, err := p.Start(ctx, ref.Container); err != nil || code != 0 {
		return fmt.Errorf("Failed to start '%s'.", ref.Container)
	}
	if err := db.WaitFor(ctx, ref, p, out); err != nil {
		return err
	}
	Ok(out, "%s is running.", ref.Container)
	// Sticky: an explicitly started database comes back on the next
	// reboot, even if no project needs it.
	return syncDatabaseState(ctx, p, s, dns, n, ref.ID, true)
}

// DBStop stops a running DB container. Its DNS record stays; the address
// is pinned to the container.
func DBStop(ctx context.Context, out io.Writer, input string,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, n net.Net) error {

	ref, err := db.Resolve(ctx, input, p)
	if err != nil {
		return err
	}
	if !p.Exists(ctx, ref.Container) {
		return fmt.Errorf("DB container '%s' does not exist.", ref.Container)
	}
	if !p.Running(ctx, ref.Container) {
		fmt.Fprintf(out, "%s is already stopped.\n", ref.Container)
		return syncDatabaseState(ctx, p, s, dns, n, ref.ID, false)
	}
	if code, err := p.Stop(ctx, ref.Container); err != nil || code != 0 {
		return fmt.Errorf("Failed to stop '%s'.", ref.Container)
	}
	Ok(out, "%s stopped.", ref.Container)
	// Clear the sticky flag: an explicit stop means stay down across a
	// reboot unless a project pulls it back up.
	return syncDatabaseState(ctx, p, s, dns, n, ref.ID, false)
}

// syncDatabaseState rebuilds the databases.json cache and DNS records,
// then records autostart for id (pass "" to leave autostart untouched).
// It must run on every path, including "already running/stopped": those
// are exactly when the cache is most likely stale.
func syncDatabaseState(ctx context.Context, p *podman.Client, s state.Store,
	dns dnsmasq.Manager, n net.Net, id string, autostart bool) error {

	if err := db.RebuildStateCache(ctx, p, s); err != nil {
		return err
	}
	if id != "" {
		if err := s.SetDatabaseAutostart(id, autostart); err != nil {
			return err
		}
	}
	return PublishDNS(ctx, io.Discard, dns, n, s, false)
}

// DBCreate creates (or starts) a DB container.
func DBCreate(ctx context.Context, out io.Writer, input string, p *podman.Client,
	s state.Store, dns dnsmasq.Manager, n net.Net, uid string) error {

	ref, err := db.Resolve(ctx, input, p)
	if err != nil {
		return err
	}
	if err := db.Ensure(ctx, ref, p, n, uid, out); err != nil {
		return err
	}
	// Creating a database explicitly is a start: make it sticky too.
	return syncDatabaseState(ctx, p, s, dns, n, ref.ID, true)
}

// DBDelete removes a DB container and its data. Data too, deliberately:
// leftover engine files would be invisible, since `list dbs` enumerates
// containers. The container is shared by every project on that
// engine:version, so the prompt names the projects that lose data.
func DBDelete(ctx context.Context, out io.Writer, in io.Reader, input string,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, n net.Net, assumeYes bool) error {

	ref, err := db.Resolve(ctx, input, p)
	if err != nil {
		return err
	}
	if !p.Exists(ctx, ref.Container) {
		return fmt.Errorf("DB container '%s' does not exist.", ref.Container)
	}

	dataDir := db.DataDir(ref.Engine, ref.Version)
	var users []string
	for _, proj := range s.Projects() {
		if proj.DatabaseID == ref.ID {
			users = append(users, proj.Name)
		}
	}
	sort.Strings(users)

	fmt.Fprintf(out, "Container: %s\n", ref.Container)
	fmt.Fprintf(out, "Data:      %s/\n", dataDir)
	if len(users) == 0 {
		fmt.Fprintln(out, "This will remove the container and every database in it.")
	} else {
		fmt.Fprintf(out, "In use by: %s\n", strings.Join(users, ", "))
		fmt.Fprintf(out, "This will remove the container and every database in it — %d project(s) will lose their data.\n", len(users))
	}

	if !assumeYes && !promptYesNo(out, in,
		fmt.Sprintf("Remove DB container '%s' and all its data?", ref.Container)) {
		fmt.Fprintln(out, "Aborted.")
		return nil
	}
	// Stop first; ignore the result so a stopped or wedged container is
	// still removable.
	_, _ = p.Stop(ctx, ref.Container)
	if code, err := p.Remove(ctx, ref.Container); err != nil || code != 0 {
		return fmt.Errorf("Failed to remove '%s'.", ref.Container)
	}
	// Remove data after the container: a failed removal must not orphan
	// data from an owner that still exists.
	if err := srv.Remove(ctx, dataDir); err != nil {
		return err
	}
	Ok(out, "'%s' and %s/ removed.", ref.Container, dataDir)
	// The row drops out of the rebuilt cache with the container.
	return syncDatabaseState(ctx, p, s, dns, n, "", false)
}

// promptYesNo asks for confirmation. Anything but an explicit yes is a
// refusal — the safe default for a destructive verb.
func promptYesNo(out io.Writer, in io.Reader, message string) bool {
	fmt.Fprintf(out, "\n%s [y/N] ", message)
	reader := bufio.NewReader(in)
	line, err := reader.ReadString('\n')
	if err != nil && line == "" {
		return false
	}
	answer := strings.ToLower(strings.TrimSpace(line))
	return answer == "y" || answer == "yes"
}

// promptName asks the caller to type the name back exactly. Used for
// `delete` and `reset`: a reflexive `y` can destroy the wrong project,
// while a typed name cannot be given by reflex. Whitespace is trimmed;
// case is not folded, since project names are lowercase by construction.
func promptName(out io.Writer, in io.Reader, name, action string) bool {
	fmt.Fprintf(out, "\nType the project name to confirm %s (or anything else to abort)\n  %s: ",
		action, name)
	reader := bufio.NewReader(in)
	line, err := reader.ReadString('\n')
	if err != nil && line == "" {
		return false
	}
	return strings.TrimSpace(line) == name
}

// ensureAutostartDatabases starts databases marked autostart plus those
// an autostart project needs; one used only by a stopped project stays
// down. Failures warn rather than abort.
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
