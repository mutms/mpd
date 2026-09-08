package service

import (
	"context"
	"fmt"
	"io"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/ui"
)

// IsRunning reports whether the service is up: the pod for a pod
// service, else the single container.
func (s Service) IsRunning(ctx context.Context, p *podman.Client) bool {
	if s.IsPod() {
		return p.PodRunning(ctx, s.PodName())
	}
	return p.Running(ctx, s.Container())
}

// memberName is a pod container's podman name: mpd-svc-<svc>-<suffix>.
func (s Service) memberName(c PodContainer) string {
	return s.Container() + "-" + c.Suffix
}

// setPodRestart flips every member container's restart policy. Stop uses
// "no" so podman-restart.service does not resurrect the pod at boot;
// Start restores "always".
func (s Service) setPodRestart(ctx context.Context, p *podman.Client, policy string) {
	for _, c := range s.PodContainers {
		_ = p.UpdateRestartPolicy(ctx, s.memberName(c), policy)
	}
}

// startPod is the pod equivalent of Start: pull images, rebuild on a
// revision change, then create or resume the pod.
func startPod(ctx context.Context, out io.Writer, s Service, n net.Net, p *podman.Client) error {
	for _, c := range s.PodContainers {
		if p.ImageExists(ctx, c.Image) {
			continue
		}
		fmt.Fprintf(out, "  Pulling %s…\n", c.Image)
		if code, err := p.Pull(ctx, c.Image); err != nil || code != 0 {
			return fmt.Errorf("Failed to pull %s.", c.Image)
		}
	}

	pod := s.PodName()
	if p.PodExists(ctx, pod) && p.PodLabel(ctx, pod, RevisionLabel) != s.Revision {
		if code, err := p.PodRemove(ctx, pod); err != nil || code != 0 {
			return fmt.Errorf("Failed to rebuild service '%s'.", s.Name)
		}
	}

	switch {
	case !p.PodExists(ctx, pod):
		if err := createPod(ctx, s, n, p); err != nil {
			return err
		}
		ui.OK(out, "%s running — %s", s.Name, s.AccessHint(n))
	case !p.PodRunning(ctx, pod):
		s.setPodRestart(ctx, p, "always")
		if code, err := p.PodStart(ctx, pod); err != nil || code != 0 {
			return fmt.Errorf("Failed to start service '%s'.", s.Name)
		}
		ui.OK(out, "%s running — %s", s.Name, s.AccessHint(n))
	default:
		s.setPodRestart(ctx, p, "always")
		ui.OK(out, "%s already running — %s", s.Name, s.AccessHint(n))
	}
	return nil
}

// createPod creates the pod (holding the service IP, DNS and restart
// policy) and each member container inside it. Network and DNS options
// live on the pod: member containers share its network namespace, so
// podman rejects those flags on them.
func createPod(ctx context.Context, s Service, n net.Net, p *podman.Client) error {
	pod := s.PodName()
	podArgs := []string{
		"--name", pod,
		"--network", "mpd-internal:ip=" + s.IP(n),
		"--label", RevisionLabel + "=" + s.Revision,
	}
	podArgs = append(podArgs, podman.DNSOpts(n.Gateway())...)
	if code, err := p.PodCreate(ctx, podArgs); err != nil || code != 0 {
		return fmt.Errorf("Failed to create pod for service '%s'.", s.Name)
	}

	for _, c := range s.PodContainers {
		args := []string{"-d",
			"--pod", pod,
			"--name", s.memberName(c),
			"--restart", "always",
			"--label", RevisionLabel + "=" + s.Revision,
		}
		if c.Volume != "" {
			args = append(args, "-v", c.Volume+":"+c.VolumePath)
		}
		args = append(args, podMemberLabels(s.Name, c)...)
		args = append(args, c.RunArgs...)
		args = append(args, c.Image)
		args = append(args, c.Args...)
		if code, err := p.Run(ctx, args); err != nil || code != 0 {
			return fmt.Errorf("Failed to create container '%s'.", s.memberName(c))
		}
	}
	return nil
}

// stopPod stops the pod and neutralizes its restart policy so a reboot
// leaves it down.
func stopPod(ctx context.Context, out io.Writer, s Service, p *podman.Client) error {
	pod := s.PodName()
	if !p.PodExists(ctx, pod) {
		ui.OK(out, "%s is not installed.", s.Name)
		return nil
	}
	s.setPodRestart(ctx, p, "no")
	if code, err := p.PodStop(ctx, pod); err != nil || code != 0 {
		return fmt.Errorf("Failed to stop service '%s'.", s.Name)
	}
	ui.OK(out, "%s stopped (will not auto-start).", s.Name)
	return nil
}

// uninstallPod removes the pod and its containers but keeps the volumes;
// Purge reclaims them.
func uninstallPod(ctx context.Context, out io.Writer, s Service, p *podman.Client) error {
	pod := s.PodName()
	if p.PodExists(ctx, pod) {
		_, _ = p.PodStop(ctx, pod)
		if code, err := p.PodRemove(ctx, pod); err != nil || code != 0 {
			return fmt.Errorf("Failed to remove service '%s'.", s.Name)
		}
	}
	for _, vol := range s.Volumes() {
		if p.VolumeExists(ctx, vol) {
			ui.OK(out, "%s uninstalled — data kept in volumes (remove with --service-purge=%s).",
				s.Name, s.Name)
			return nil
		}
	}
	ui.OK(out, "%s uninstalled.", s.Name)
	return nil
}

// podMemberLabels stamps a pod container. Only the primary carries
// mpd.name=<svc>, the label the status views key on; helpers get a
// suffixed name so they do not shadow the service's own state.
func podMemberLabels(svc string, c PodContainer) []string {
	name := svc
	if !c.Primary {
		name = svc + "-" + c.Suffix
	}
	return commonLabels(name)
}
