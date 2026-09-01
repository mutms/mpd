// Package podman is the single shared gateway for container operations.
//
// Every container operation in mpd goes through this package, and only
// internal/exec runs host commands; see docs/architecture.md
// §"Mandatory Constraint". Add new podman invocations here, not at call
// sites. Podman runs rootful, so every invocation uses `sudo -n`.
package podman

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/mutms/mpd/go/internal/exec"
)

// PsItem is one container as reported by `podman ps --format json`.
// Field names must match podman's JSON exactly.
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

// Label reads one label, returning "" when absent.
func (p PsItem) Label(key string) string {
	if p.Labels == nil {
		return ""
	}
	return p.Labels[key]
}

// Client runs podman commands. The type exists so tests can substitute
// a runner instead of shelling out.
type Client struct {
	run Runner
	// attach connects the caller's stdin as well as stdout/stderr, for
	// interactive children (`mpd run`).
	attach StreamRunner
	// stream passes podman's own output through. Lifecycle commands
	// print the container name, and that output is part of mpd's
	// visible behaviour.
	stream StreamRunner
}

// StreamRunner runs a podman invocation without capturing its output,
// returning the exit code.
type StreamRunner func(ctx context.Context, args []string) (int, error)

// Runner captures a podman invocation. Tests supply a stub.
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
		attach: func(ctx context.Context, args []string) (int, error) {
			return exec.Run(ctx, exec.Cmd{
				Name: "podman", Args: args, Sudo: true, Stdin: os.Stdin,
			})
		},
	}
}

// NewWith returns a Client backed by a custom runner, for tests.
func NewWith(r Runner) *Client {
	return &Client{
		run: r,
		stream: func(ctx context.Context, args []string) (int, error) {
			res, err := r(ctx, args)
			return res.Code, err
		},
		attach: func(ctx context.Context, args []string) (int, error) {
			res, err := r(ctx, args)
			return res.Code, err
		},
	}
}

// LabelManaged is the default filter: every container mpd creates carries it.
const LabelManaged = "label=mpd.managed=true"

// Ps lists containers matching a label filter, including stopped ones.
// A failed or unparseable listing yields an empty slice: "none found"
// is the truthful answer when podman cannot be asked.
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
// The subnet is fixed at creation, so this is the authority over
// whatever mpd currently computes; `--vm-setup` refuses on a mismatch.
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

// Start starts an existing container.
func (c *Client) Start(ctx context.Context, name string) (int, error) {
	return c.stream(ctx, []string{"start", name})
}

// Stop stops a running container.
func (c *Client) Stop(ctx context.Context, name string) (int, error) {
	return c.stream(ctx, []string{"stop", name})
}

// UpdateRestartPolicy changes an existing container's restart policy
// ("always", "no"). This is what makes --service-stop stick across
// reboots: podman-restart.service resurrects anything left on "always".
func (c *Client) UpdateRestartPolicy(ctx context.Context, name, policy string) error {
	res, err := c.run(ctx, []string{"update", "--restart", policy, name})
	if err != nil {
		return err
	}
	if res.Code != 0 {
		return fmt.Errorf("podman update --restart %s %s failed", policy, name)
	}
	return nil
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

// OptMountRO bind-mounts the mpd checkout read-only at the same
// absolute path inside a container, so /opt/mpd/assets/... resolves
// identically on both sides.
var OptMountRO = []string{"-v", "/opt/mpd:/opt/mpd:ro"}

// Pull fetches an image, streaming layer progress so a first,
// hundreds-of-megabytes pull is visible.
func (c *Client) Pull(ctx context.Context, image string) (int, error) {
	return c.stream(ctx, []string{"pull", image})
}

// Run creates and starts a container (`podman run`).
func (c *Client) Run(ctx context.Context, args []string) (int, error) {
	return c.stream(ctx, append([]string{"run"}, args...))
}

// VolumeRemove removes a named volume. `pod rm` leaves named volumes
// behind, so they must be reclaimed explicitly.
func (c *Client) VolumeRemove(ctx context.Context, name string) (int, error) {
	res, err := c.run(ctx, []string{"volume", "rm", name})
	if err != nil {
		return -1, err
	}
	return res.Code, nil
}

// VolumeMountpoint returns the host path backing a named volume.
// Asked, not assumed: the layout under podman's storage directory is
// podman's business.
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

// NetworkCreate creates a bridge network with a fixed subnet and
// podman's own DNS turned off (see docs/networking.md for why).
// iface pins the bridge name: mpd's resolver names that interface in
// its config, and podman's own podman0/podman1 counter is not stable.
//
// ipRange keeps netavark's IPAM off the low octets the VM holds itself
// (the gateway and the project address). Without it a container created
// with no pinned address takes one of them and breaks the frontdoor.
func (c *Client) NetworkCreate(ctx context.Context, name, iface, subnet, ipRange string) (int, error) {
	res, err := c.run(ctx, []string{
		"network", "create",
		"--subnet", subnet,
		"--ip-range", ipRange,
		"--interface-name", iface,
		"--disable-dns",
		name,
	})
	if err != nil {
		return -1, err
	}
	return res.Code, nil
}

// NetworkInterface reports the host bridge a podman network uses.
// Read, not assumed: a network created before mpd pinned the name
// still carries podman's own.
func (c *Client) NetworkInterface(ctx context.Context, name string) string {
	res, err := c.run(ctx, []string{
		"network", "inspect", name, "--format", "{{.NetworkInterface}}",
	})
	if err != nil || res.Code != 0 {
		return ""
	}
	return strings.TrimSpace(res.Stdout)
}

// NetworkDNSEnabled reports whether podman's own DNS is on for a
// network. True means aardvark-dns still owns the gateway's port 53;
// that cannot be turned off in place, so the caller reports it rather
// than repairing it.
func (c *Client) NetworkDNSEnabled(ctx context.Context, name string) bool {
	res, err := c.run(ctx, []string{
		"network", "inspect", name, "--format", "{{.DNSEnabled}}",
	})
	if err != nil || res.Code != 0 {
		return false
	}
	return strings.TrimSpace(res.Stdout) == "true"
}

// DNSOpts is the resolver configuration every mpd container and pod is
// created with: mpd's own resolver on the bridge gateway, exactly one
// nameserver, short glibc timeouts, and no base hosts file. The
// reasoning is in docs/networking.md §DNS.
func DNSOpts(gateway string) []string {
	return []string{
		"--dns", gateway,
		"--dns-option", "timeout:1",
		"--dns-option", "attempts:2",
		"--hosts-file", "none",
	}
}

// RemoveIfOutdated removes a container whose labels no longer match
// what mpd would create today, so the caller's "create if missing"
// step rebuilds it. A container matching every checked label is left
// alone. Reports whether anything was removed.
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
// streaming its output. The orchestrator sets the identity here, as
// AGENTS.md's privilege rule requires; scripts never switch users
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

// ImageExists reports whether an image is present locally.
func (c *Client) ImageExists(ctx context.Context, image string) bool {
	res, err := c.run(ctx, []string{"image", "exists", image})
	return err == nil && res.Code == 0
}

// BuildImage builds an image from a context directory, stamping it with
// the given labels so a later check can tell a stale build from a
// current one.
func (c *Client) BuildImage(ctx context.Context, tag, contextDir string, labels map[string]string) (int, error) {
	args := []string{"build", "-t", tag}
	for _, key := range sortedKeys(labels) {
		args = append(args, "--label", key+"="+labels[key])
	}
	args = append(args, contextDir)
	return c.stream(ctx, args)
}

// ImageLabel reads one label off a built image, "" when the image or
// label is missing.
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

// sortedKeys keeps generated arguments deterministic.
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
