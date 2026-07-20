package service

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/ui"
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
	if err := ensureBuiltImage(ctx, out, p, AdminerImage, "adminer"); err != nil {
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
