package project

import (
	"context"
	"encoding/json"
	"io"

	"github.com/mutms/mpd/go/internal/srv"
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

// Rescan rebuilds projects.json from what is actually on the data
// volume.
//
// The volume outlives the state directory — wiping /var/lib/mpd/state is
// the documented way to reset mpd, and the projects survive it — so the
// volume is the authority on which projects EXIST. Lifecycle intent
// (requested, runtimeName) is not on the volume, so an entry already in
// the cache keeps its own; only genuinely new projects are added, as
// stopped and unassigned.
func Rescan(ctx context.Context, out io.Writer, s state.Store) error {
	ui.Step(out, "Scanning data volume for project metadata")

	var found []metaJSON
	for _, path := range srv.ProjectMetaFiles() {
		raw, ok := srv.Read(path)
		if !ok {
			continue
		}
		var m metaJSON
		if json.Unmarshal([]byte(raw), &m) != nil || m.Name == "" {
			continue
		}
		found = append(found, m)
	}

	if len(found) == 0 {
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
