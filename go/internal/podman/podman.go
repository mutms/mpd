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
}

// Runner captures a podman invocation. Production uses internal/exec;
// tests supply a stub, which is what makes everything above this package
// testable without a container engine.
type Runner func(ctx context.Context, args []string) (exec.Result, error)

// New returns a Client that runs the real podman binary via sudo.
func New() *Client {
	return &Client{run: func(ctx context.Context, args []string) (exec.Result, error) {
		return exec.Capture(ctx, exec.Cmd{Name: "podman", Args: args, Sudo: true})
	}}
}

// NewWith returns a Client backed by a custom runner, for tests.
func NewWith(r Runner) *Client { return &Client{run: r} }

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
