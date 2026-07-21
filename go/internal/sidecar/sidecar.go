// Package sidecar manages the containers attached alongside a runtime.
//
// A runtime is a pod; sidecars join it and share its network namespace,
// so they reach the main container on localhost and are reachable at the
// runtime's own address. That is why the frontdoor can proxy to
// 127.0.0.1 and why selenium needs no address of its own.
//
// The attached set is *derived*, never stored: it is recomputed from the
// runtime's declared defaults, its projects' type requirements, and the
// URL kinds those projects publish. Reconciling is therefore idempotent
// and self-correcting — nothing to drift out of sync with reality.
package sidecar

import (
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/state"
)

// Spec describes one sidecar.
type Spec struct {
	// Role is the stable name ("frontdoor", "selenium"). It derives both
	// the container name and the mpd.role label.
	Role string
	// Image reference: localhost/… for images mpd builds, docker.io/…
	// for upstream.
	Image string
	// BuildContext is a path under assets/ holding a Containerfile. When
	// set and the image is absent locally, mpd builds rather than pulls.
	BuildContext string
	// ExtraArgs are appended to `podman run` after the standard flags.
	ExtraArgs []string
}

// ContainerName is the sidecar's container within a pod:
// role "frontdoor" + pod "mpd-150-php" → "mpd-150-php-frontdoor".
func (s Spec) ContainerName(pod string) string { return pod + "-" + s.Role }

// Frontdoor terminates TLS and routes by urls.json. Opt-in per runtime:
// php and node declare it because they serve in-zone project URLs; util
// does not, since utility types expose none.
func Frontdoor() Spec {
	return Spec{
		Role:         "frontdoor",
		Image:        "localhost/mpd-caddy-sidecar:latest",
		BuildContext: "sidecars/caddy",
		// Read-only: it needs urls.json and per-project certs, nothing more.
		ExtraArgs: []string{"-v", "mpd-data-volume:/srv:ro"},
	}
}

// Mailpit catches SMTP on localhost:1025 with a UI on :8025, per runtime.
func Mailpit() Spec {
	return Spec{Role: "mailpit", Image: "docker.io/axllent/mailpit:latest"}
}

// Selenium serves WebDriver on localhost:4444, attached only when a
// project publishes a behat URL — the image is ~1.5 GB, so it is pulled
// on demand rather than by default.
func Selenium() Spec {
	return Spec{
		Role:  "selenium",
		Image: "docker.io/selenium/standalone-chromium:latest",
		// Env-only config. Note /dev/shm sizing is NOT here: pod members
		// share the infra container's IPC namespace, so a per-container
		// --shm-size is ignored and the pod carries it instead.
		//
		// OVERRIDE_MAX_SESSIONS is required because Selenium otherwise
		// clamps sessions to the CPU count, which throttles parallel
		// Behat runs. SCREEN_* matches Moodle's default Behat window so
		// responsive-layout steps behave.
		ExtraArgs: []string{
			"-e", "SE_NODE_MAX_SESSIONS=10",
			"-e", "SE_NODE_OVERRIDE_MAX_SESSIONS=true",
			"-e", "SE_SCREEN_WIDTH=1400",
			"-e", "SE_SCREEN_HEIGHT=800",
		},
	}
}

// Valkey is a Redis-compatible cache on localhost:6379, attached when a
// project type declares it.
func Valkey() Spec {
	return Spec{Role: "valkey", Image: "docker.io/valkey/valkey:8"}
}

// SpecFor resolves a role name. The single place to extend when adding a
// sidecar — an unknown role is skipped rather than erroring, so an asset
// naming a future sidecar does not break an older binary.
func SpecFor(role string) (Spec, bool) {
	switch role {
	case "frontdoor":
		return Frontdoor(), true
	case "mailpit":
		return Mailpit(), true
	case "selenium":
		return Selenium(), true
	case "valkey":
		return Valkey(), true
	default:
		return Spec{}, false
	}
}

// Desired computes the sidecar set a runtime should have, from three
// signals combined in order:
//
//  1. the runtime's own defaultSidecars,
//  2. each resident project type's declared sidecars,
//  3. URL kinds — any project publishing a behat URL pulls in selenium.
//
// Deduped, order-preserving, unknown roles dropped.
func Desired(runtime string, s state.Store, a assets.Tree) []Spec {
	var roles []string

	if cfg, ok := a.RuntimeConfig(runtime); ok {
		roles = append(roles, cfg.DefaultSidecars...)
	}

	var projects []state.Project
	for _, p := range s.Projects() {
		if p.RuntimeName == runtime {
			projects = append(projects, p)
		}
	}
	for _, p := range projects {
		if cfg, ok := a.ProjectTypeSidecars(p.Type); ok {
			roles = append(roles, cfg...)
		}
	}
	for _, p := range projects {
		for _, u := range p.URLs {
			if u.Kind == "behat" {
				roles = append(roles, "selenium")
			}
		}
	}

	seen := map[string]bool{}
	var specs []Spec
	for _, role := range roles {
		if seen[role] {
			continue
		}
		seen[role] = true
		if spec, ok := SpecFor(role); ok {
			specs = append(specs, spec)
		}
	}
	return specs
}

// Attached lists the roles currently on a pod, read from labels rather
// than from any stored list — the containers are the truth.
func Attached(ctx context.Context, p *podman.Client, pod string) map[string]bool {
	roles := map[string]bool{}
	for _, item := range p.Ps(ctx, "label=mpd.role") {
		if item.Label("mpd.pod") != pod {
			continue
		}
		role := item.Label("mpd.role")
		if strings.HasSuffix(role, "-sidecar") {
			roles[strings.TrimSuffix(role, "-sidecar")] = true
		}
	}
	return roles
}

// Attach adds a sidecar to a pod, building or pulling its image first.
// Idempotent: an existing container is started if stopped, else left be.
func Attach(ctx context.Context, out io.Writer, spec Spec, pod string, p *podman.Client) error {
	if err := ensureImage(ctx, out, spec, p); err != nil {
		return err
	}

	name := spec.ContainerName(pod)
	if p.Exists(ctx, name) {
		if !p.Running(ctx, name) {
			if _, err := p.Start(ctx, name); err != nil {
				return err
			}
		}
		return nil
	}

	args := append([]string{}, podman.OptMountRO...)
	args = append(args,
		"-d", "--name", name, "--pod", pod,
		"--label", "mpd.managed=true",
		"--label", "mpd.role="+spec.Role+"-sidecar",
		"--label", "mpd.pod="+pod,
		"--restart", "always",
	)
	args = append(args, spec.ExtraArgs...)
	args = append(args, spec.Image)

	if code, err := p.Run(ctx, args); err != nil || code != 0 {
		return fmt.Errorf("Failed to attach %s sidecar to '%s'.", spec.Role, pod)
	}
	return nil
}

// Detach removes every container on a pod carrying a role's label.
// Matched by label rather than by name because a pod could in principle
// hold more than one container for a role.
func Detach(ctx context.Context, role, pod string, p *podman.Client) {
	for _, item := range p.Ps(ctx, "label=mpd.role="+role+"-sidecar") {
		if item.Label("mpd.pod") != pod || item.Name() == "" {
			continue
		}
		_, _ = p.Remove(ctx, item.Name())
	}
}

// Reconcile brings a pod's sidecars in line with the desired set:
// attaches what is missing, removes what is extra.
func Reconcile(ctx context.Context, out io.Writer, pod string, desired []Spec, p *podman.Client) error {
	if !p.PodExists(ctx, pod) {
		return nil
	}
	attached := Attached(ctx, p, pod)

	wanted := map[string]bool{}
	for _, spec := range desired {
		wanted[spec.Role] = true
		if !attached[spec.Role] {
			if err := Attach(ctx, out, spec, pod, p); err != nil {
				return err
			}
		}
	}
	for role := range attached {
		if !wanted[role] {
			Detach(ctx, role, pod, p)
		}
	}
	return nil
}

// ensureImage builds a sidecar image from assets when it declares a
// build context, else pulls it. No-op when already present locally.
func ensureImage(ctx context.Context, out io.Writer, spec Spec, p *podman.Client) error {
	if p.ImageExists(ctx, spec.Image) {
		return nil
	}
	if spec.BuildContext == "" {
		if code, err := p.PullQuiet(ctx, spec.Image); err != nil || code != 0 {
			return fmt.Errorf("Failed to pull sidecar image '%s'.", spec.Image)
		}
		return nil
	}
	contextDir := assets.Dir + "/" + spec.BuildContext
	fmt.Fprintf(out, "\n\033[1m==> Building sidecar image '%s'\033[0m\n", spec.Image)
	if code, err := p.BuildImage(ctx, spec.Image, contextDir, nil); err != nil || code != 0 {
		return fmt.Errorf("Failed to build sidecar image '%s' from %s.", spec.Image, contextDir)
	}
	return nil
}
