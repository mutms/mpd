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
	"context"
	"encoding/json"
	"fmt"
	"sort"

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

// Label reads one label, returning "" when absent. A missing label and
// an empty one are the same thing to every caller here.
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
	// stream runs a command with podman's own stdout/stderr passed
	// through to ours. Lifecycle commands (start/stop/restart) print the
	// container name, and that output is part of mpd's visible
	// behaviour — capturing it would silently change what the user sees.
	stream StreamRunner
}

// StreamRunner runs a podman invocation without capturing its output,
// returning the exit code.
type StreamRunner func(ctx context.Context, args []string) (int, error)

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
	}
}

// LabelManaged is the default filter: every container mpd creates carries it.
const LabelManaged = "label=mpd.managed=true"

// Ps lists containers matching a label filter, including stopped ones.
//
// A failed or unparseable listing yields an empty slice rather than an
// error: callers render "none found", which is the truthful answer when
// podman cannot be asked.
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
// it will get. `--vm-setup` compares the two and refuses when they disagree.
func (c *Client) NetworkSubnet(ctx context.Context, name string) string {
	res, err := c.run(ctx, []string{
		"network", "inspect", name, "--format", "{{range .Subnets}}{{.Subnet}}{{end}}",
	})
	if err != nil || res.Code != 0 {
		return ""
	}
	return res.Stdout
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

// VolumeMountpoint returns the host path backing a named volume.
//
// Asked rather than assumed: the layout under
// /var/lib/containers/storage/volumes/ is podman's business, and mpd
// bind-mounts this path onto /srv, so reading it back is the difference
// between following podman and guessing at it.
func (c *Client) VolumeMountpoint(ctx context.Context, name string) (string, bool) {
	res, err := c.run(ctx, []string{
		"volume", "inspect", name, "--format", "{{.Mountpoint}}",
	})
	if err != nil || res.Code != 0 || res.Stdout == "" {
		return "", false
	}
	return res.Stdout, true
}

// VolumeExists reports whether a named volume is present.
func (c *Client) VolumeExists(ctx context.Context, name string) bool {
	res, err := c.run(ctx, []string{"volume", "exists", name})
	return err == nil && res.Code == 0
}

// VolumeCreate creates a named volume.
func (c *Client) VolumeCreate(ctx context.Context, name string) (int, error) {
	res, err := c.run(ctx, []string{"volume", "create", name})
	if err != nil {
		return -1, err
	}
	return res.Code, nil
}

// --- Networks ---------------------------------------------------------

// NetworkExists reports whether a podman network is defined.
func (c *Client) NetworkExists(ctx context.Context, name string) bool {
	res, err := c.run(ctx, []string{"network", "exists", name})
	return err == nil && res.Code == 0
}

// NetworkCreate creates a bridge network with a fixed subnet and the DNS
// servers containers on it should use.
//
// The DNS servers are set on the network rather than per container, so
// every container that attaches — runtimes, sidecars, service containers,
// DB containers — resolves mpd names without each create having to
// remember a --dns flag.
func (c *Client) NetworkCreate(ctx context.Context, name, subnet string, dnsServers []string) (int, error) {
	args := []string{"network", "create", "--subnet", subnet}
	for _, s := range dnsServers {
		args = append(args, "--dns", s)
	}
	args = append(args, name)
	res, err := c.run(ctx, args)
	if err != nil {
		return -1, err
	}
	return res.Code, nil
}

// RemoveIfOutdated removes a container whose labels no longer match what
// mpd would create today, so the caller's "create if missing" step
// rebuilds it.
//
// This is how service containers pick up a changed image, mount set, or
// CA: each carries a revision label and a CA-fingerprint label, and a
// mismatch on either means the running container is stale. A container
// that matches on every checked label is left alone — that is the common
// case on a repeat `--vm-setup`, and rebuilding it would be pure churn.
//
// Reports whether anything was removed.
func (c *Client) RemoveIfOutdated(ctx context.Context, name string, labels map[string]string) bool {
	if !c.Exists(ctx, name) {
		return false
	}
	for key, want := range labels {
		if c.Label(ctx, name, key) != want {
			c.Remove(ctx, name)
			return true
		}
	}
	return false
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

// PodExists reports whether a pod exists.
func (c *Client) PodExists(ctx context.Context, pod string) bool {
	res, err := c.run(ctx, []string{"pod", "exists", pod})
	return err == nil && res.Code == 0
}

// ImageExists reports whether an image is present locally.
func (c *Client) ImageExists(ctx context.Context, image string) bool {
	res, err := c.run(ctx, []string{"image", "exists", image})
	return err == nil && res.Code == 0
}

// PullQuiet fetches an image without streaming layer progress. Used for
// sidecars, where the pull is incidental to the operation the user asked
// for rather than the point of it.
func (c *Client) PullQuiet(ctx context.Context, image string) (int, error) {
	res, err := c.run(ctx, []string{"pull", "-q", image})
	if err != nil {
		return -1, err
	}
	return res.Code, nil
}

// BuildImage builds an image from a context directory, stamping it with
// the given labels.
//
// Labels are how a caller can later tell an image built from today's
// Containerfile from one built months ago: an existence check cannot see
// that the recipe changed.
func (c *Client) BuildImage(ctx context.Context, tag, contextDir string, labels map[string]string) (int, error) {
	args := []string{"build", "-t", tag}
	for _, key := range sortedKeys(labels) {
		args = append(args, "--label", key+"="+labels[key])
	}
	args = append(args, contextDir)
	return c.stream(ctx, args)
}

// ImageLabel reads one label off a built image. Empty when the image is
// missing or has no such label — both mean "not what we asked for".
func (c *Client) ImageLabel(ctx context.Context, image, key string) string {
	res, err := c.run(ctx, []string{
		"image", "inspect", image, "--format", fmt.Sprintf("{{index .Labels %q}}", key),
	})
	if err != nil || res.Code != 0 {
		return ""
	}
	return res.Stdout
}

// ImageRemove deletes an image by tag, ignoring "no such image".
func (c *Client) ImageRemove(ctx context.Context, image string) {
	_, _ = c.run(ctx, []string{"rmi", "-f", image})
}

// sortedKeys keeps generated arguments deterministic, so unchanged input
// never produces a different command line.
func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// ExecCapture runs a command inside a container and captures its output.
func (c *Client) ExecCapture(ctx context.Context, container string, command ...string) (exec.Result, error) {
	args := append([]string{"exec", container}, command...)
	return c.run(ctx, args)
}

// Mounts every mpd-created container gets, at identical absolute paths
// inside and out so asset and env lookups resolve the same either side.
var (
	// EnvMountRO carries user-editable VM-wide overrides. Mounted as a
	// DIRECTORY, not a file, so vim/nano atomic-rename writes on the VM
	// propagate into running containers — a file mount would pin the old
	// inode.
	EnvMountRO = []string{"-v", "/var/lib/mpd/env:/var/lib/mpd/env:ro"}
	// SkelMountRO carries user-managed dotfile defaults for new runtimes.
	SkelMountRO = []string{"-v", "/var/lib/mpd/skel:/var/lib/mpd/skel:ro"}
)

// PodCreate creates a pod.
func (c *Client) PodCreate(ctx context.Context, args []string) (int, error) {
	return c.stream(ctx, append([]string{"pod", "create"}, args...))
}

// Copy copies between host and container (`podman cp`); either side may
// be `container:/path`.
func (c *Client) Copy(ctx context.Context, src, dst string) (int, error) {
	res, err := c.run(ctx, []string{"cp", src, dst})
	if err != nil {
		return -1, err
	}
	return res.Code, nil
}
