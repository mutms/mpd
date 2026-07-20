// Command mpd is the Go implementation of the mpd control plane.
//
// During the port it is built as `bin/gompd` and installed alongside the
// Swift `bin/mpd`; the two share state through the JSON files under
// /var/lib/mpd/state/, podman labels, and container names. Only one of
// them may write at a time. See docs/proposals/go-port.md.
package main

import (
	"fmt"
	"os"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/cli"
	"github.com/mutms/mpd/go/internal/current"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/spf13/cobra"
)

// version is stamped at build time via -ldflags.
var version = "dev"

func main() {
	root := &cobra.Command{
		Use:   "mpd",
		Short: "Moodle Plugin Development environment",
		Long: "mpd — Moodle Plugin Development environment.\n\n" +
			"Go implementation, in progress. Verbs land one at a time;\n" +
			"see docs/proposals/go-port.md for what is ported so far.",
		SilenceUsage:  true,
		SilenceErrors: true,
		// No bare-invocation TUI: the Swift TUI is not being ported, and
		// its replacement is a web UI. Bare `mpd` will become `mpd list`
		// once list lands; until then, show help.
		RunE: func(cmd *cobra.Command, args []string) error {
			return cmd.Help()
		},
	}

	root.AddCommand(versionCmd(), netCmd(), listCmd())

	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}

func versionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print the mpd version",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println(version)
			return nil
		},
	}
}

// netCmd reports this VM's addressing. It is the first real verb because
// it exercises the whole identity path end to end — read platform.env,
// derive the subnet and zone — and because its output can be compared
// directly against what the Swift binary and /srv/meta/vm.json say.
func netCmd() *cobra.Command {
	var platformEnv string
	cmd := &cobra.Command{
		Use:   "net",
		Short: "Show this VM's container subnet and DNS zone",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			n, err := net.Load(platformEnv)
			if err != nil {
				return err
			}
			out := cmd.OutOrStdout()
			fmt.Fprintf(out, "vm id       %s\n", n.VMID())
			fmt.Fprintf(out, "zone        %s\n", n.Zone())
			fmt.Fprintf(out, "subnet      %s\n", n.Subnet())
			fmt.Fprintf(out, "gateway     %s\n", n.Gateway())
			fmt.Fprintf(out, "dnsmasq     %s\n", n.IP(net.HostDnsmasq))
			fmt.Fprintf(out, "portal      %s\n", n.IP(net.HostPortal))
			fmt.Fprintf(out, "fileaccess  %s\n", n.IP(net.HostFileaccess))
			fmt.Fprintf(out, "adminer     %s\n", n.IP(net.HostAdminer))
			return nil
		},
	}
	cmd.Flags().StringVar(&platformEnv, "platform-env", net.PlatformEnvPath,
		"path to platform.env (override for testing)")
	return cmd
}

// listCmd mirrors the Swift `mpd list [projects|runtimes|services|dbs]`.
func listCmd() *cobra.Command {
	return &cobra.Command{
		Use:       "list [projects|runtimes|services|dbs]",
		Short:     "List entities — projects (default), runtimes, services, or DB containers",
		ValidArgs: []string{"projects", "runtimes", "services", "dbs"},
		Args:      cobra.MatchAll(cobra.MaximumNArgs(1), cobra.OnlyValidArgs),
		RunE: func(cmd *cobra.Command, args []string) error {
			what := "projects"
			if len(args) == 1 {
				what = args[0]
			}
			n, err := net.Load(net.PlatformEnvPath)
			if err != nil {
				return err
			}
			out := cmd.OutOrStdout()
			ctx := cmd.Context()
			p, s, a := podman.New(), state.New(), assets.New()

			switch what {
			case "projects":
				cli.ListProjects(ctx, out, s, current.NewObserver(n.VMID(), p))
			case "runtimes":
				cli.ListRuntimes(ctx, out, n, p, s, a)
			case "services":
				cli.ListServices(ctx, out, n, p)
			case "dbs":
				cli.ListDatabases(ctx, out, n, p, s)
			}
			return nil
		},
	}
}
