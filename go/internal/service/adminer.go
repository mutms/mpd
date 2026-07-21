package service

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/ui"
	"github.com/mutms/mpd/go/internal/vm"
)

// SetupAdminer creates and starts the adminer container.
//
// Built from Debian rather than pulled as docker.io/library/adminer:
// that image is Alpine-based, and libpq on musl fails to resolve
// multi-label hostnames like `postgres-latest.db.<zone>` — which is
// every database name mpd publishes. The symptom is an opaque
// `SQLSTATE[08006] could not translate host name`.
func SetupAdminer(ctx context.Context, out io.Writer, p *podman.Client, n net.Net) error {
	ui.Step(out, "Service: adminer")
	if err := ensureBuiltImage(ctx, out, p, AdminerImage, "adminer", adminerRevision); err != nil {
		return err
	}

	d, ok := Find("adminer")
	if !ok {
		return fmt.Errorf("adminer is not in the service registry.")
	}
	container := d.Container
	p.RemoveIfOutdated(ctx, container, map[string]string{
		RevisionLabel: adminerRevision,
	})

	switch {
	case !p.Exists(ctx, container):
		args := append([]string{}, podman.OptMountRO...)
		args = append(args,
			"-d", "--name", container,
			"--network", "mpd-internal:ip="+d.IP(n),
			"--restart", "always",
			"--label", RevisionLabel+"="+adminerRevision,
		)
		args = append(args, commonLabels("adminer")...)
		args = append(args, AdminerImage)
		if code, err := p.Run(ctx, args); err != nil || code != 0 {
			return fmt.Errorf("Failed to create service 'adminer'.")
		}
		ui.OK(out, "adminer running.")
	case !p.Running(ctx, container):
		if _, err := p.Start(ctx, container); err != nil {
			return err
		}
		ui.OK(out, "adminer running.")
	default:
		ui.OK(out, "adminer already running.")
	}
	return nil
}

// ensureBuiltImage builds a service image from its assets directory when
// it is missing, or when the image present was built from an older
// revision.
//
// Existence alone is not enough. The revision tracks the service's
// Containerfile and entrypoint, so an image built before those changed is
// stale even though it is present — and the staleness is invisible:
// RemoveIfOutdated recreates the container, it comes up healthy, and it
// runs the old entrypoint. Rebuilding on a label mismatch is what makes
// bumping a revision mean anything for image changes.
func ensureBuiltImage(ctx context.Context, out io.Writer, p *podman.Client, tag, name, revision string) error {
	if p.ImageExists(ctx, tag) {
		if p.ImageLabel(ctx, tag, RevisionLabel) == revision {
			return nil
		}
		ui.Step(out, "Rebuilding %s image (revision changed)", name)
		p.ImageRemove(ctx, tag)
	}
	contextDir := vm.AssetsDir + "/services/" + name
	ui.Step(out, "Building %s image", name)
	if code, err := p.BuildImage(ctx, tag, contextDir,
		map[string]string{RevisionLabel: revision}); err != nil || code != 0 {
		return fmt.Errorf("Failed to build %s image from %s.", name, contextDir)
	}
	return nil
}
