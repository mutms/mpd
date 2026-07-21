// Package srv reads and writes the data volume, which the VM sees at
// /srv.
//
// The volume is bind-mounted onto /srv by the srv.mount unit
// (internal/vm), so these are ordinary file operations. Podman is rootful
// and a runtime's dev user is created with the VM user's uid, so files
// written here come out owned correctly with no chown step, and a
// container sees them at the identical path.
//
// Removal is the one exception and goes through internal/exec: database
// engines write their files as their own uid (postgres and mariadb both
// use 999), so deleting a database's data directory needs root.
package srv

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/mutms/mpd/go/internal/exec"
)

// The data volume's layout, as mounted on the VM.
const (
	Dir      = "/srv"
	Projects = Dir + "/projects"
	Meta     = Dir + "/meta"
	DBs      = Dir + "/dbs"
	Backups  = Dir + "/backups"
	Extra    = Dir + "/extra"
)

// MetaDir is a project's metadata directory.
func MetaDir(project string) string { return filepath.Join(Meta, project) }

// MetaFile is one file in a project's metadata directory.
func MetaFile(project, name string) string { return filepath.Join(MetaDir(project), name) }

// ProjectDir is a project's source tree.
func ProjectDir(project string) string { return filepath.Join(Projects, project) }

// Read returns a file's contents, and whether it could be read. A missing
// file is not an error — "no such project metadata yet" is a normal
// state, and every caller treats it as one.
func Read(path string) (string, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	return string(data), true
}

// Write creates the parent directory and writes the file atomically:
// temp file in the same directory, then rename.
//
// Atomic because consumers watch these directories. The Caddy frontdoor
// re-validates on every change, and a half-written cert.pem fails
// validation, so the reload is skipped and Caddy serves the previous
// cert until something restarts it. A rename is never observed partial.
func Write(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), perm); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// WriteJSON marshals v indented and writes it atomically.
func WriteJSON(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return Write(path, data, 0o644)
}

// MkdirAll creates a directory on the volume.
func MkdirAll(path string) error { return os.MkdirAll(path, 0o775) }

// EnsureLayout creates the top-level directories, owned by the dev user.
//
// Privileged, and unavoidably so: the volume's root is root-owned (podman
// creates it), so the dev user cannot make a directory directly beneath
// it. Everything *inside* these directories is then dev-owned, which is
// why no other write on the volume needs sudo.
//
// Also a repair: `install -d` re-asserts ownership and mode on every run,
// correcting anything a root-context write left behind.
func EnsureLayout(ctx context.Context, uid string) error {
	if uid == "" {
		return fmt.Errorf("cannot lay out %s: no uid", Dir)
	}
	for _, dir := range []string{Projects, Dir + "/data", Meta, DBs, Backups, Extra} {
		code, err := exec.Run(ctx, exec.Cmd{
			Name: "install",
			Args: []string{"-d", "-o", uid, "-g", uid, "-m", "0775", dir},
			Sudo: true,
		})
		if err != nil {
			return fmt.Errorf("creating %s: %w", dir, err)
		}
		if code != 0 {
			return fmt.Errorf("creating %s: exit %d", dir, code)
		}
	}
	return nil
}

// Remove deletes a path and everything under it, as root.
//
// Root, not the dev user: database engines write their files as their own
// uid, so the dev user cannot unlink them. Doing this unprivileged fails
// on every file — silently, if the caller ignores the error, which is how
// a "removed" message gets printed over data that is still there.
func Remove(ctx context.Context, path string) error {
	// Refuse anything outside the volume. This runs `rm -rf` as root, so
	// a caller that composed a path wrongly must not be able to take the
	// VM with it.
	clean := filepath.Clean(path)
	if clean != Dir && !strings.HasPrefix(clean, Dir+"/") {
		return fmt.Errorf("refusing to remove %q: outside %s", path, Dir)
	}
	if clean == Dir {
		return fmt.Errorf("refusing to remove the whole data volume")
	}
	if _, err := os.Stat(clean); os.IsNotExist(err) {
		return nil
	}
	code, err := exec.Run(ctx, exec.Cmd{
		Name: "rm", Args: []string{"-rf", clean}, Sudo: true,
	})
	if err != nil {
		return fmt.Errorf("removing %s: %w", clean, err)
	}
	if code != 0 {
		return fmt.Errorf("removing %s: exit %d", clean, code)
	}
	return nil
}

// ListProjects returns the project directories present on the volume,
// sorted. The volume is the authority on which projects exist — it
// outlives /var/lib/mpd/state, which is the documented way to reset mpd.
func ListProjects() []string {
	entries, err := os.ReadDir(Projects)
	if err != nil {
		return nil
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names
}

// ReadMetaJSON decodes /srv/meta/<project>/<name> into v, reporting
// whether it could be read and parsed. Both failures are the same to
// callers: there is nothing usable there.
func ReadMetaJSON(project, name string, v any) bool {
	raw, ok := Read(MetaFile(project, name))
	if !ok {
		return false
	}
	return json.Unmarshal([]byte(raw), v) == nil
}

// ProjectMetaFiles returns every /srv/meta/*/project.json on the volume,
// sorted by project name.
func ProjectMetaFiles() []string {
	matches, err := filepath.Glob(filepath.Join(Meta, "*", "project.json"))
	if err != nil {
		return nil
	}
	sort.Strings(matches)
	return matches
}
