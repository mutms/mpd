package cli

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/mutms/mpd/go/internal/db"
	"github.com/mutms/mpd/go/internal/dnsmasq"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/state"
)

// Ok prints a success line. ANSI is emitted unconditionally — matching
// the Swift helper, which does not check isatty. Changing that would
// change output the difftest compares, so it stays as-is until the flag
// day.
func Ok(out io.Writer, format string, args ...any) {
	fmt.Fprintf(out, "\033[1;32m✓ "+format+"\033[0m\n", args...)
}

// DBStart starts a stopped DB container.
func DBStart(ctx context.Context, out io.Writer, input string,
	p *podman.Client, s state.Store, dns dnsmasq.Manager) error {

	ref, err := db.Resolve(ctx, input, p)
	if err != nil {
		return err
	}
	if !p.Exists(ctx, ref.Container) {
		return fmt.Errorf("DB container '%s' does not exist. Use --db-create to create it.", ref.Container)
	}
	if p.Running(ctx, ref.Container) {
		fmt.Fprintf(out, "%s is already running.\n", ref.Container)
		return syncDatabaseState(ctx, p, s, dns)
	}
	if code, err := p.Start(ctx, ref.Container); err != nil || code != 0 {
		return fmt.Errorf("Failed to start '%s'.", ref.Container)
	}
	if err := db.WaitFor(ctx, ref, p, out); err != nil {
		return err
	}
	Ok(out, "%s is running.", ref.Container)
	return syncDatabaseState(ctx, p, s, dns)
}

// DBStop stops a running DB container.
func DBStop(ctx context.Context, out io.Writer, input string,
	p *podman.Client, s state.Store, dns dnsmasq.Manager) error {

	ref, err := db.Resolve(ctx, input, p)
	if err != nil {
		return err
	}
	if !p.Exists(ctx, ref.Container) {
		return fmt.Errorf("DB container '%s' does not exist.", ref.Container)
	}
	if !p.Running(ctx, ref.Container) {
		fmt.Fprintf(out, "%s is already stopped.\n", ref.Container)
		return syncDatabaseState(ctx, p, s, dns)
	}
	if code, err := p.Stop(ctx, ref.Container); err != nil || code != 0 {
		return fmt.Errorf("Failed to stop '%s'.", ref.Container)
	}
	Ok(out, "%s stopped.", ref.Container)
	return syncDatabaseState(ctx, p, s, dns)
}

// syncDatabaseState reconciles both derived artifacts after any DB
// lifecycle change: the databases.json cache and dnsmasq's records.
//
// Both must happen on *every* path, including the "already running" and
// "already stopped" ones. Those look like no-ops but are exactly when
// the cache is most likely to be stale — something changed the container
// outside mpd, which is why the user is running the command.
func syncDatabaseState(ctx context.Context, p *podman.Client, s state.Store, dns dnsmasq.Manager) error {
	if err := db.RebuildStateCache(ctx, p, s); err != nil {
		return err
	}
	changed, err := dns.EnsureDatabaseRecords(ctx)
	if err != nil {
		return err
	}
	if changed {
		return dns.Restart(ctx)
	}
	return nil
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
	return syncDatabaseState(ctx, p, s, dns)
}

// DBDelete removes a DB container and its data.
//
// Both, deliberately: `mpd delete <project>` removes the DB, dataroot,
// source and config together, so a DB delete that left 150 MB of engine
// files behind would be inconsistent — and invisible, since `list dbs`
// enumerates containers, not data directories.
//
// The blast radius is wider than one project: a container is shared by
// every project on that engine:version, so the prompt names the projects
// that will lose data rather than describing it abstractly.
func DBDelete(ctx context.Context, out io.Writer, in io.Reader, input string,
	p *podman.Client, s state.Store, dns dnsmasq.Manager, assumeYes bool) error {

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
	// Stop first; ignore the result. A container that is already stopped
	// or wedged should still be removable — rm -f handles it.
	_, _ = p.Stop(ctx, ref.Container)
	if code, err := p.Remove(ctx, ref.Container); err != nil || code != 0 {
		return fmt.Errorf("Failed to remove '%s'.", ref.Container)
	}
	// After the container: a failed removal must not leave data orphaned
	// from an owner that still exists.
	if err := p.VolumeRemoveAll(ctx, dataDir); err != nil {
		return err
	}
	Ok(out, "'%s' and %s/ removed.", ref.Container, dataDir)
	return syncDatabaseState(ctx, p, s, dns)
}

// promptYesNo asks for confirmation, defaulting to no. Anything other
// than an explicit yes is a refusal — the default must be the safe
// answer for a destructive verb.
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
