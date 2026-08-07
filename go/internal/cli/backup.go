package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/current"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/runtime"
	"github.com/mutms/mpd/go/internal/srv"
)

// runtimeBackupsDir is where runtime backups land on the data volume —
// visible at the same path on the VM and inside the runtime, which is
// what lets VM-side Go orchestrate scripts that run in the container.
var runtimeBackupsDir = filepath.Join(srv.Backups, "runtime")

// backupManifest records what a backup run did, next to its files.
type backupManifest struct {
	CreatedAt string   `json:"createdAt"`
	Scripts   []string `json:"scripts"`
}

// RuntimeBackup saves the runtime's non-project data — Claude Code
// configuration, shell history — into a timestamped directory under
// /srv/backups/runtime/.
//
// Configuration and history only, never binaries: a rebuilt runtime
// reinstalls its tools fresh (that is the point of a rebuild), so
// restore hooks re-run installers rather than copying executables back.
//
// The work is asset-side: every assets/runtime/backup.d/*.sh runs
// inside the runtime as the dev user with the backup directory as $1.
// Adding a topic means dropping a script there, no Go change.
func RuntimeBackup(ctx context.Context, out io.Writer, p *podman.Client,
	o current.Observer, devUser string) error {

	container := o.RuntimeContainer(runtime.Name)
	if !p.Running(ctx, container) {
		return fmt.Errorf("The runtime is not running — nothing to back up from. Run: mpd --vm-setup")
	}

	scripts, err := hookScripts("backup.d")
	if err != nil {
		return err
	}
	if len(scripts) == 0 {
		return fmt.Errorf("No backup scripts under %s/%s/backup.d/.", assets.Dir, assets.RuntimeDir)
	}

	stamp := time.Now().UTC().Format("20060102-150405Z")
	dir := filepath.Join(runtimeBackupsDir, stamp)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}

	fmt.Fprintf(out, "\n\033[1m==> Backing up runtime data to %s\033[0m\n", dir)
	var ran []string
	for _, script := range scripts {
		if code, err := p.ExecAsUser(ctx, container, devUser, "bash", script, dir); err != nil || code != 0 {
			return fmt.Errorf("backup script %s failed.", filepath.Base(script))
		}
		ran = append(ran, filepath.Base(script))
	}

	manifest, err := json.MarshalIndent(backupManifest{
		CreatedAt: stamp,
		Scripts:   ran,
	}, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "manifest.json"), append(manifest, '\n'), 0o644); err != nil {
		return err
	}

	Ok(out, "Runtime data backed up to %s", dir)
	fmt.Fprintln(out, "  Restore into a (rebuilt) runtime with: mpd --runtime-restore")
	return nil
}

// RuntimeRestore replays the newest backup into the runtime: every
// assets/runtime/restore.d/*.sh runs inside the runtime as the dev user
// with the backup directory as $1. Each script no-ops when the backup
// carries nothing for its topic.
func RuntimeRestore(ctx context.Context, out io.Writer, p *podman.Client,
	o current.Observer, devUser string) error {

	container := o.RuntimeContainer(runtime.Name)
	if !p.Running(ctx, container) {
		return fmt.Errorf("The runtime is not running — nothing to restore into. Run: mpd --vm-setup")
	}

	dir, err := newestBackup()
	if err != nil {
		return err
	}
	scripts, err := hookScripts("restore.d")
	if err != nil {
		return err
	}
	if len(scripts) == 0 {
		return fmt.Errorf("No restore scripts under %s/%s/restore.d/.", assets.Dir, assets.RuntimeDir)
	}

	fmt.Fprintf(out, "\n\033[1m==> Restoring runtime data from %s\033[0m\n", dir)
	for _, script := range scripts {
		if code, err := p.ExecAsUser(ctx, container, devUser, "bash", script, dir); err != nil || code != 0 {
			return fmt.Errorf("restore script %s failed.", filepath.Base(script))
		}
	}

	Ok(out, "Runtime data restored from %s", dir)
	return nil
}

// hookScripts lists the *.sh files of one backup/restore layer, sorted —
// the numeric-prefix convention (10-, 20-, …) is the ordering contract.
func hookScripts(layer string) ([]string, error) {
	dir := filepath.Join(assets.Dir, assets.RuntimeDir, layer)
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var scripts []string
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".sh" {
			continue
		}
		scripts = append(scripts, filepath.Join(dir, e.Name()))
	}
	sort.Strings(scripts)
	return scripts, nil
}

// newestBackup picks the latest timestamped directory. The stamps are
// UTC and lexicographically ordered by construction, so the newest is
// simply the last name.
func newestBackup() (string, error) {
	entries, err := os.ReadDir(runtimeBackupsDir)
	if err != nil || len(entries) == 0 {
		return "", fmt.Errorf("No runtime backups found under %s/. Run: mpd --runtime-backup", runtimeBackupsDir)
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			names = append(names, e.Name())
		}
	}
	if len(names) == 0 {
		return "", fmt.Errorf("No runtime backups found under %s/. Run: mpd --runtime-backup", runtimeBackupsDir)
	}
	sort.Strings(names)
	return filepath.Join(runtimeBackupsDir, names[len(names)-1]), nil
}
