// Package podman is the single shared gateway for container operations.
//
// **Mandatory architecture rule** (AGENTS.md, docs/ARCHITECTURE.md §3):
// every container/runtime operation in mpd goes through this package, and
// the only package permitted to run host commands at all is
// internal/exec. Layers above (cli, runtime, service, action) must not
// shell out — they ask here.
//
// Adding a new podman invocation? Add a method here, not a one-off call
// somewhere else.
//
// Podman runs rootful in the VM, so every invocation goes through
// `sudo -n`; that is applied here rather than at each call site.
package podman

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"

	"github.com/mutms/mpd/go/internal/exec"
)

// PsItem is one container as reported by `podman ps --format json`.
// Field names match podman's JSON exactly, so they stay capitalised.
type PsItem struct {
	Names  []string          `json:"Names"`
	Labels map[string]string `json:"Labels"`
	State  string            `json:"State"`
}

// Name is the container's first name, or "" when podman reported none.
func (p PsItem) Name() string {
	if len(p.Names) == 0 {
		return ""
	}
	return p.Names[0]
}

// Label reads one label, returning "" when absent — matching how the
// Swift implementation treated a missing label.
func (p PsItem) Label(key string) string {
	if p.Labels == nil {
		return ""
	}
	return p.Labels[key]
}

// Client runs podman commands. It holds no state; the type exists so
// tests can substitute a runner instead of shelling out.
type Client struct {
	run Runner
	// input pipes data to a command's stdin — how file contents reach
	// the data volume without a host-side bind mount.
	input InputRunner
	// stream runs a command with podman's own stdout/stderr passed
	// through to ours. Lifecycle commands (start/stop/restart) print the
	// container name, and that output is part of mpd's visible
	// behaviour — capturing it would silently change what the user sees.
	stream StreamRunner
}

// StreamRunner runs a podman invocation without capturing its output,
// returning the exit code.
type StreamRunner func(ctx context.Context, args []string) (int, error)

// InputRunner runs a podman invocation with data piped to stdin.
type InputRunner func(ctx context.Context, args []string, stdin []byte) (int, error)

// Runner captures a podman invocation. Production uses internal/exec;
// tests supply a stub, which is what makes everything above this package
// testable without a container engine.
type Runner func(ctx context.Context, args []string) (exec.Result, error)

// New returns a Client that runs the real podman binary via sudo.
func New() *Client {
	return &Client{
		run: func(ctx context.Context, args []string) (exec.Result, error) {
			return exec.Capture(ctx, exec.Cmd{Name: "podman", Args: args, Sudo: true})
		},
		stream: func(ctx context.Context, args []string) (int, error) {
			return exec.Run(ctx, exec.Cmd{Name: "podman", Args: args, Sudo: true})
		},
		input: func(ctx context.Context, args []string, stdin []byte) (int, error) {
			return exec.Run(ctx, exec.Cmd{
				Name: "podman", Args: args, Sudo: true, Stdin: bytes.NewReader(stdin),
			})
		},
	}
}

// NewWith returns a Client backed by a custom runner, for tests. Streamed
// commands fall back to the same runner, discarding their output.
func NewWith(r Runner) *Client {
	return &Client{
		run: r,
		stream: func(ctx context.Context, args []string) (int, error) {
			res, err := r(ctx, args)
			return res.Code, err
		},
		input: func(ctx context.Context, args []string, _ []byte) (int, error) {
			res, err := r(ctx, args)
			return res.Code, err
		},
	}
}

// LabelManaged is the default filter: every container mpd creates carries it.
const LabelManaged = "label=mpd.managed=true"

// Ps lists containers matching a label filter, including stopped ones.
//
// A failed or unparseable listing yields an empty slice rather than an
// error, mirroring the Swift behaviour: callers render "none found",
// which is the truthful answer when podman cannot be asked.
func (c *Client) Ps(ctx context.Context, filter string) []PsItem {
	res, err := c.run(ctx, []string{"ps", "-a", "--filter", filter, "--format", "json"})
	if err != nil || res.Code != 0 {
		return nil
	}
	return parsePs(res.Stdout)
}

func parsePs(out string) []PsItem {
	if out == "" || out == "null" {
		return nil
	}
	var items []PsItem
	if err := json.Unmarshal([]byte(out), &items); err != nil {
		return nil
	}
	return items
}

// Exists reports whether a container exists in any state.
func (c *Client) Exists(ctx context.Context, name string) bool {
	res, err := c.run(ctx, []string{"container", "exists", name})
	return err == nil && res.Code == 0
}

// Running reports whether a container is currently running.
func (c *Client) Running(ctx context.Context, name string) bool {
	res, err := c.run(ctx, []string{"inspect", name, "--format", "{{.State.Running}}"})
	return err == nil && res.Stdout == "true"
}

// Label reads one label from a container, "" when missing.
func (c *Client) Label(ctx context.Context, container, key string) string {
	res, err := c.run(ctx, []string{
		"inspect", container, "--format", fmt.Sprintf("{{index .Config.Labels %q}}", key),
	})
	if err != nil || res.Code != 0 {
		return ""
	}
	return res.Stdout
}

// ContainerIP reads a container's address on a podman network. Index
// notation, not dot notation: network names contain hyphens.
func (c *Client) ContainerIP(ctx context.Context, name, network string) string {
	res, err := c.run(ctx, []string{
		"inspect", name, "--format",
		fmt.Sprintf("{{(index .NetworkSettings.Networks %q).IPAddress}}", network),
	})
	if err != nil || res.Code != 0 {
		return ""
	}
	return res.Stdout
}

// NetworkSubnet reports the CIDR a podman network was created with.
//
// A network's subnet is fixed at creation, so this — not what mpd
// currently computes — is the authority on what addresses containers on
// it will get. `--setup` compares the two and refuses when they disagree.
func (c *Client) NetworkSubnet(ctx context.Context, name string) string {
	res, err := c.run(ctx, []string{
		"network", "inspect", name, "--format", "{{range .Subnets}}{{.Subnet}}{{end}}",
	})
	if err != nil || res.Code != 0 {
		return ""
	}
	return res.Stdout
}

// --- Data volume access ----------------------------------------------
//
// The /srv data volume is reached through the always-on
// mpd-service-fileaccess container, which has it mounted. `podman exec`
// into a running container is 5-10x faster than `podman run --rm` per
// call, which matters because project create/configure does many small
// volume operations.
//
// Execs run as the dev user's uid so files written here come out owned
// by the runtime user, with no chown step afterwards.

// FileAccessContainer is the always-on container holding the data volume.
const FileAccessContainer = "mpd-service-fileaccess"

// VolumeRead returns the contents of a file on the data volume, and
// whether it could be read. A missing file is not an error — "no such
// project metadata yet" is a normal state.
func (c *Client) VolumeRead(ctx context.Context, path string, uid string) (string, bool) {
	args := []string{"exec"}
	args = append(args, userOptions(uid)...)
	args = append(args, FileAccessContainer, "bash", "-c",
		fmt.Sprintf("test -f %s && cat %s || true", path, path))
	res, err := c.run(ctx, args)
	if err != nil || res.Code != 0 || res.Stdout == "" {
		return "", false
	}
	return res.Stdout, true
}

// VolumeRemoveAll deletes a path on the data volume, as root.
//
// Root, not the dev user: database engines write their files as their
// own uid (postgres and mariadb both use 999) and /srv/dbs itself is
// root-owned, so the dev user cannot unlink them. Running this as the
// dev user fails on every file — silently, if the caller ignores the
// exit code, which is how a "removed" message can be printed over data
// that is still there.
//
// The exit code IS checked here, so a destructive verb cannot report
// success for work it did not do.
func (c *Client) VolumeRemoveAll(ctx context.Context, path string) error {
	res, err := c.run(ctx, []string{"exec", FileAccessContainer, "rm", "-rf", path})
	if err != nil {
		return fmt.Errorf("removing %s: %w", path, err)
	}
	if res.Code != 0 {
		return fmt.Errorf("removing %s: exit %d: %s", path, res.Code, res.Stderr)
	}
	return nil
}

// VolumeExec runs a command against the data volume and captures stdout.
func (c *Client) VolumeExec(ctx context.Context, uid string, command ...string) (exec.Result, error) {
	args := []string{"exec"}
	args = append(args, userOptions(uid)...)
	args = append(args, FileAccessContainer)
	args = append(args, command...)
	return c.run(ctx, args)
}

func userOptions(uid string) []string {
	if uid == "" {
		return nil
	}
	return []string{"--user", uid + ":" + uid}
}

// --- Lifecycle -------------------------------------------------------
//
// These stream podman's output rather than capturing it: `podman stop`
// prints the container name, and that line is part of what the user
// sees from `mpd --db-stop`. Swallowing it would change behaviour.

// Start starts an existing container.
func (c *Client) Start(ctx context.Context, name string) (int, error) {
	return c.stream(ctx, []string{"start", name})
}

// Stop stops a running container.
func (c *Client) Stop(ctx context.Context, name string) (int, error) {
	return c.stream(ctx, []string{"stop", name})
}

// Restart restarts a container.
func (c *Client) Restart(ctx context.Context, name string) (int, error) {
	return c.stream(ctx, []string{"restart", name})
}

// Remove force-removes a container.
func (c *Client) Remove(ctx context.Context, name string) (int, error) {
	return c.stream(ctx, []string{"rm", "-f", name})
}

// ExecQuietly runs a command inside a container, discarding output, and
// returns the exit code. Used for readiness probes.
func (c *Client) ExecQuietly(ctx context.Context, container string, command ...string) int {
	args := append([]string{"exec", container}, command...)
	res, err := c.run(ctx, args)
	if err != nil {
		return -1
	}
	return res.Code
}

// OptMountRO bind-mounts the mpd checkout read-only at the same absolute
// path inside a container, so /opt/mpd/assets/... resolves identically on
// the VM and inside every container mpd creates.
var OptMountRO = []string{"-v", "/opt/mpd:/opt/mpd:ro"}

// Pull fetches an image, streaming layer progress.
//
// Explicit pre-pull rather than letting `run -d` pull silently: a first
// pull is hundreds of megabytes and the user should see it happening.
// A cached pull returns in under a second.
func (c *Client) Pull(ctx context.Context, image string) (int, error) {
	return c.stream(ctx, []string{"pull", image})
}

// Run creates and starts a container (`podman run`).
func (c *Client) Run(ctx context.Context, args []string) (int, error) {
	return c.stream(ctx, append([]string{"run"}, args...))
}

// VolumeMkdirAll creates a directory on the data volume.
func (c *Client) VolumeMkdirAll(ctx context.Context, uid, path string) error {
	_, err := c.VolumeExec(ctx, uid, "mkdir", "-p", path)
	return err
}

// --- Pods -------------------------------------------------------------
//
// A runtime is a pod: the main container plus its sidecars share one
// network namespace and one address, so lifecycle operations apply to
// the pod rather than to each container.

// PodStart starts every container in a pod.
func (c *Client) PodStart(ctx context.Context, pod string) (int, error) {
	return c.stream(ctx, []string{"pod", "start", pod})
}

// PodStop stops every container in a pod.
func (c *Client) PodStop(ctx context.Context, pod string) (int, error) {
	return c.stream(ctx, []string{"pod", "stop", pod})
}

// PodRemove force-removes a pod and its containers.
func (c *Client) PodRemove(ctx context.Context, pod string) (int, error) {
	return c.stream(ctx, []string{"pod", "rm", "-f", pod})
}

// VolumeRemove removes a named volume. `pod rm` leaves named volumes
// behind, so a runtime's disk-backed /tmp volume must be reclaimed
// explicitly or it accumulates on every recreate.
func (c *Client) VolumeRemove(ctx context.Context, name string) (int, error) {
	res, err := c.run(ctx, []string{"volume", "rm", name})
	if err != nil {
		return -1, err
	}
	return res.Code, nil
}

// VolumeWrite pipes data into a shell command running against the data
// volume — how mpd puts file contents there without a host bind mount.
//
// Callers write to a temp path and rename, because consumers watch these
// directories: the Caddy frontdoor re-validates on every change, and a
// half-written cert.pem fails validation and gets the reload skipped.
func (c *Client) VolumeWrite(ctx context.Context, uid, script string, data []byte) error {
	args := []string{"exec", "-i"}
	args = append(args, userOptions(uid)...)
	args = append(args, FileAccessContainer, "bash", "-c", script)
	code, err := c.input(ctx, args, data)
	if err != nil {
		return err
	}
	if code != 0 {
		return fmt.Errorf("writing to data volume failed (exit %d)", code)
	}
	return nil
}

// ExecAsUser runs a command inside a container as a named user or uid,
// streaming its output.
//
// Project scripts run as the dev *user name* (not uid) — inside a
// runtime that account exists and owns /srv, and asset scripts assume
// they are it. This is the orchestrator setting the identity, which is
// what AGENTS.md's privilege rule requires: scripts never switch users
// themselves.
func (c *Client) ExecAsUser(ctx context.Context, container, user string, command ...string) (int, error) {
	args := []string{"exec"}
	if user != "" {
		args = append(args, "--user", user)
	}
	args = append(args, container)
	args = append(args, command...)
	return c.stream(ctx, args)
}

// ExecWithOptions runs a command inside a container with extra podman
// options before the container name (--env, --user, …), streaming output.
func (c *Client) ExecWithOptions(ctx context.Context, container string, options []string,
	command ...string) (int, error) {
	args := append([]string{"exec"}, options...)
	args = append(args, container)
	args = append(args, command...)
	return c.stream(ctx, args)
}
