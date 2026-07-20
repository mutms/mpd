package project

import (
	"context"
	"encoding/json"
	"io"
	"strings"

	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/ui"
)

// metaJSON is the subset of /srv/meta/<project>/project.json a rescan
// needs. The file has more in it; everything else is owned by whatever
// wrote it and is none of the cache's business.
type metaJSON struct {
	Name            string `json:"name"`
	Type            string `json:"type"`
	DatabaseEngine  string `json:"databaseEngine"`
	DatabaseVersion string `json:"databaseVersion"`
	DatabaseID      string `json:"databaseId"`
}

// collectScript concatenates every project.json on the volume into one
// JSON array, so a rescan is a single exec rather than one per project.
const collectScript = `result="["; first=1
for f in /srv/meta/*/project.json; do
    [ -f "$f" ] || continue
    content=$(cat "$f")
    [ $first -eq 1 ] && result="$result$content" && first=0 || result="$result,$content"
done
echo "${result}]"`

// Rescan rebuilds projects.json from what is actually on the data
// volume.
//
// The volume outlives the state directory — wiping /var/lib/mpd/state is
// the documented way to reset mpd, and the projects survive it — so the
// volume is the authority on which projects EXIST. Lifecycle intent
// (requested, runtimeName) is not on the volume, so an entry already in
// the cache keeps its own; only genuinely new projects are added, as
// stopped and unassigned.
func Rescan(ctx context.Context, out io.Writer, p *podman.Client, s state.Store, uid string) error {
	ui.Step(out, "Scanning data volume for project metadata")

	res, err := p.VolumeExec(ctx, uid, "bash", "-c", collectScript)
	if err != nil || res.Code != 0 {
		ui.Warn(out, "Could not scan data volume (volume may be empty).")
		return nil
	}

	var found []metaJSON
	body := strings.TrimSpace(res.Stdout)
	if body == "" || body == "[]" || json.Unmarshal([]byte(body), &found) != nil {
		if err := s.SaveProjects(nil); err != nil {
			return err
		}
		ui.OK(out, "No projects found.")
		return nil
	}

	existing := map[string]state.Project{}
	for _, p := range s.Projects() {
		existing[p.Name] = p
	}

	var projects []state.Project
	for _, e := range found {
		if e.Name == "" {
			continue
		}
		if known, ok := existing[e.Name]; ok {
			projects = append(projects, known)
			continue
		}
		projects = append(projects, state.Project{
			Name:            e.Name,
			Type:            e.Type,
			DatabaseID:      e.DatabaseID,
			DatabaseEngine:  e.DatabaseEngine,
			DatabaseVersion: e.DatabaseVersion,
			Requested:       "stopped",
		})
	}
	if err := s.SaveProjects(projects); err != nil {
		return err
	}
	ui.OK(out, "Rescanned %d project(s) from data volume.", len(projects))
	return nil
}
