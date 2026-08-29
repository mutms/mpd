// Package srv reads and writes the data volume, mounted on the VM at
// /srv. Writes are ordinary file operations. Removal goes through
// internal/exec as root, because database engines own their data files.
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

// Read returns a file's contents, and whether it could be read.
// A missing file is a normal state, not an error.
func Read(path string) (string, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	return string(data), true
}

// Write creates the parent directory and writes the file atomically:
// temp file in the same directory, then rename. Consumers watch these
// directories, and a rename is never observed partial.
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
// Privileged: the volume's root is root-owned, so the dev user cannot
// create beneath it. `install -d` also repairs ownership on every run.
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

// Remove deletes a path and everything under it, as root: database
// engines write files as their own uid, so the dev user cannot unlink them.
func Remove(ctx context.Context, path string) error {
	clean, err := insideVolume(path)
	if err != nil {
		return err
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

// DataDir is a project's data directory: dataroot and its behat/phpunit
// siblings live inside it.
func DataDir(project string) string { return filepath.Join(Dir, "data", project) }

// RemoveContents deletes everything inside a directory, keeping the
// directory itself. Root, for the same reason as Remove. The directory
// survives so its provisioned ownership and mode survive; recreating it
// would hand it a different owner. A missing directory is not an error.
func RemoveContents(ctx context.Context, path string) error {
	clean, err := insideVolume(path)
	if err != nil {
		return err
	}
	entries, err := os.ReadDir(clean)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("reading %s: %w", clean, err)
	}
	if len(entries) == 0 {
		return nil
	}

	args := []string{"-rf"}
	for _, e := range entries {
		args = append(args, filepath.Join(clean, e.Name()))
	}
	code, err := exec.Run(ctx, exec.Cmd{Name: "rm", Args: args, Sudo: true})
	if err != nil {
		return fmt.Errorf("emptying %s: %w", clean, err)
	}
	if code != 0 {
		return fmt.Errorf("emptying %s: exit %d", clean, code)
	}
	return nil
}

// insideVolume validates a path for the privileged removal helpers:
// a wrongly composed path must not let a root `rm -rf` leave /srv.
func insideVolume(path string) (string, error) {
	clean := filepath.Clean(path)
	if clean != Dir && !strings.HasPrefix(clean, Dir+"/") {
		return "", fmt.Errorf("refusing to touch %q: outside %s", path, Dir)
	}
	if clean == Dir {
		return "", fmt.Errorf("refusing to empty the whole data volume")
	}
	return clean, nil
}

// ListProjects returns the project directories on the volume, sorted.
// The volume is the authority on which projects exist; it outlives
// /var/lib/mpd/state.
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
// whether it could be read and parsed.
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
