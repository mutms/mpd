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

// Start installs and runs a service, leaving it auto-restarting via
// --restart always. Idempotent: a running service is reported, not
// rebuilt, unless its Revision moved.
func Start(ctx context.Context, out io.Writer, s Service, n net.Net, p *podman.Client) error {
	ui.Step(out, "Service: %s", s.Name)

	if err := ensureImage(ctx, out, s, p); err != nil {
		return err
	}

	container := s.Container()
	p.RemoveIfOutdated(ctx, container, map[string]string{
		RevisionLabel: s.Revision,
	})

	switch {
	case !p.Exists(ctx, container):
		args := []string{"-d",
			"--name", container,
			"--network", "mpd-internal:ip=" + s.IP(n),
			"--restart", "always",
			"--label", RevisionLabel + "=" + s.Revision,
		}
		if s.Volume != "" {
			args = append(args, "-v", s.Volume+":"+s.VolumePath)
		}
		args = append(args, podman.DNSOpts(n.Gateway())...)
		args = append(args, commonLabels(s.Name)...)
		args = append(args, s.RunArgs...)
		args = append(args, s.Image)
		if code, err := p.Run(ctx, args); err != nil || code != 0 {
			return fmt.Errorf("Failed to create service '%s'.", s.Name)
		}
		ui.OK(out, "%s running — %s", s.Name, s.AccessHint(n))
	case !p.Running(ctx, container):
		// Restore the restart policy before starting, or the next
		// reboot leaves the service down again.
		_ = p.UpdateRestartPolicy(ctx, container, "always")
		if code, err := p.Start(ctx, container); err != nil || code != 0 {
			return fmt.Errorf("Failed to start service '%s'.", s.Name)
		}
		ui.OK(out, "%s running — %s", s.Name, s.AccessHint(n))
	default:
		_ = p.UpdateRestartPolicy(ctx, container, "always")
		ui.OK(out, "%s already running — %s", s.Name, s.AccessHint(n))
	}
	return nil
}

// Stop stops a service and flips its restart policy off; without that,
// podman-restart.service would resurrect it at the next boot.
func Stop(ctx context.Context, out io.Writer, s Service, p *podman.Client) error {
	ui.Step(out, "Service: %s", s.Name)
	container := s.Container()
	if !p.Exists(ctx, container) {
		ui.OK(out, "%s is not installed.", s.Name)
		return nil
	}
	_ = p.UpdateRestartPolicy(ctx, container, "no")
	if p.Running(ctx, container) {
		if code, err := p.Stop(ctx, container); err != nil || code != 0 {
			return fmt.Errorf("Failed to stop service '%s'.", s.Name)
		}
	}
	ui.OK(out, "%s stopped (will not auto-start).", s.Name)
	return nil
}

// Uninstall removes the container but keeps the volume; --service-purge
// is the destructive step.
func Uninstall(ctx context.Context, out io.Writer, s Service, p *podman.Client) error {
	ui.Step(out, "Service: %s", s.Name)
	container := s.Container()
	if p.Exists(ctx, container) {
		_, _ = p.Stop(ctx, container)
		if code, err := p.Remove(ctx, container); err != nil || code != 0 {
			return fmt.Errorf("Failed to remove service '%s'.", s.Name)
		}
	}
	if s.Volume != "" && p.VolumeExists(ctx, s.Volume) {
		ui.OK(out, "%s uninstalled — data kept in volume %s (remove with --service-purge=%s).",
			s.Name, s.Volume, s.Name)
	} else {
		ui.OK(out, "%s uninstalled.", s.Name)
	}
	return nil
}

// Purge removes what Uninstall keeps: the service's data volume.
func Purge(ctx context.Context, out io.Writer, s Service, p *podman.Client) error {
	if err := Uninstall(ctx, out, s, p); err != nil {
		return err
	}
	if s.Volume == "" {
		return nil
	}
	if p.VolumeExists(ctx, s.Volume) {
		if code, err := p.VolumeRemove(ctx, s.Volume); err != nil || code != 0 {
			return fmt.Errorf("Failed to remove volume '%s'.", s.Volume)
		}
		ui.OK(out, "volume %s purged.", s.Volume)
	}
	return nil
}

// ensureImage builds (BuildContext) or pulls the service's image.
// For built images, existence alone is not enough: an image built before
// the revision changed is stale, and the staleness is invisible.
func ensureImage(ctx context.Context, out io.Writer, s Service, p *podman.Client) error {
	if s.BuildContext == "" {
		if p.ImageExists(ctx, s.Image) {
			return nil
		}
		fmt.Fprintf(out, "  Pulling %s (this can be large — selenium is ~2 GB)…\n", s.Image)
		if code, err := p.Pull(ctx, s.Image); err != nil || code != 0 {
			return fmt.Errorf("Failed to pull %s.", s.Image)
		}
		return nil
	}

	if p.ImageExists(ctx, s.Image) {
		if p.ImageLabel(ctx, s.Image, RevisionLabel) == s.Revision {
			return nil
		}
		ui.Step(out, "Rebuilding %s image (revision changed)", s.Name)
		p.ImageRemove(ctx, s.Image)
	}
	contextDir := vm.AssetsDir + "/services/" + s.BuildContext
	ui.Step(out, "Building %s image", s.Name)
	if code, err := p.BuildImage(ctx, s.Image, contextDir,
		map[string]string{RevisionLabel: s.Revision}); err != nil || code != 0 {
		return fmt.Errorf("Failed to build %s image from %s.", s.Name, contextDir)
	}
	return nil
}
