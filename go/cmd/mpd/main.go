// Command mpd is the Go implementation of the mpd control plane.
//
// During the port it is built as `bin/gompd` and installed alongside the
// Swift `bin/mpd`; the two share state through the JSON files under
// /var/lib/mpd/state/, podman labels, and container names. Only one of
// them may write at a time. See docs/proposals/go-port.md.
package main

import (
	"context"
	"fmt"
	"os"
	"strconv"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/cli"
	"github.com/mutms/mpd/go/internal/current"
	"github.com/mutms/mpd/go/internal/dnsmasq"
	"github.com/mutms/mpd/go/internal/hooks"
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

	root.AddCommand(versionCmd(), netCmd(), listCmd(), showCmd(), runtimeCmd(), dbCmd(),
		projectStartCmd(), projectStopCmd(), projectDeleteCmd(), projectConfigureCmd(),
		projectCreateCmd(), checkHooksCmd())

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

// devUID is the uid volume execs run as, so files written to the data
// volume come out owned by the runtime user.
func devUID() string {
	return strconv.Itoa(os.Getuid())
}

func showCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "show <project>",
		Short: "Show project details",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			n, err := net.Load(net.PlatformEnvPath)
			if err != nil {
				return err
			}
			p := podman.New()
			cli.ShowProject(cmd.Context(), cmd.OutOrStdout(), args[0], state.New(), p,
				current.NewObserver(n.VMID(), p), n, devUID())
			return nil
		},
	}
}

func runtimeCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "runtime <name>",
		Short: "Show runtime details and its projects",
		Args:  cobra.ExactArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			n, err := net.Load(net.PlatformEnvPath)
			if err != nil {
				return err
			}
			p := podman.New()
			return cli.ShowRuntime(c.Context(), c.OutOrStdout(), args[0], state.New(), p,
				current.NewObserver(n.VMID(), p), n)
		},
	}

	var assumeYes bool

	stopCmd := &cobra.Command{
		Use:   "stop <name>",
		Short: "Stop a running runtime",
		Args:  cobra.ExactArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			n, p, s, dns, o, err := runtimeDeps()
			if err != nil {
				return err
			}
			_ = n
			return cli.RuntimeStop(c.Context(), c.OutOrStdout(), args[0], p, s, dns, o)
		},
	}

	deleteCmd := &cobra.Command{
		Use:   "delete <name>",
		Short: "Stop and remove a runtime and its containers",
		Args:  cobra.ExactArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			n, p, s, dns, o, err := runtimeDeps()
			if err != nil {
				return err
			}
			_ = n
			user := os.Getenv("USER")
			if user == "" {
				user = "user"
			}
			return cli.RuntimeDelete(c.Context(), c.OutOrStdout(), c.InOrStdin(), args[0],
				p, s, dns, o, user, assumeYes)
		},
	}
	deleteCmd.Flags().BoolVar(&assumeYes, "yes", false, "Skip the confirmation prompt")

	startCmd := &cobra.Command{
		Use:   "start <name>",
		Short: "Start a stopped runtime and restore its projects",
		Args:  cobra.ExactArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			n, p, s, dns, o, err := runtimeDeps()
			if err != nil {
				return err
			}
			user := os.Getenv("USER")
			if user == "" {
				user = "user"
			}
			return cli.RuntimeStart(c.Context(), c.OutOrStdout(), args[0], p, s, dns, o, n,
				user, devUID())
		},
	}

	createCmd := &cobra.Command{
		Use:   "create <name>",
		Short: "Provision a new runtime",
		Args:  cobra.ExactArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			n, p, s, dns, o, err := runtimeDeps()
			if err != nil {
				return err
			}
			user := os.Getenv("USER")
			if user == "" {
				user = "user"
			}
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			return cli.RuntimeCreate(c.Context(), c.OutOrStdout(), args[0], p, s, dns, o, n,
				assets.New(), user, devUID(), home)
		},
	}

	cmd.AddCommand(createCmd, startCmd, stopCmd, deleteCmd)
	return cmd
}

func runtimeDeps() (net.Net, *podman.Client, state.Store, dnsmasq.Manager, current.Observer, error) {
	n, err := net.Load(net.PlatformEnvPath)
	if err != nil {
		return net.Net{}, nil, state.Store{}, dnsmasq.Manager{}, current.Observer{}, err
	}
	p := podman.New()
	return n, p, state.New(), dnsmasq.New(state.Dir, n, p), current.NewObserver(n.VMID(), p), nil
}

// dbCmd groups the DB container verbs. Swift spells these as flags
// (--db-start); the Go CLI uses subcommands, and difftest compares the
// pair until the flag day settles it.
func dbCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "db", Short: "Manage database containers"}

	build := func(use, short string, run func(context.Context, *cobra.Command, string) error) *cobra.Command {
		return &cobra.Command{
			Use:   use,
			Short: short,
			Args:  cobra.ExactArgs(1),
			RunE: func(c *cobra.Command, args []string) error {
				return run(c.Context(), c, args[0])
			},
		}
	}

	var assumeYes bool

	createCmd := build("create <engine:version>", "Create (or start) a DB container",
		func(ctx context.Context, c *cobra.Command, arg string) error {
			p, s, dns, err := dbDeps()
			if err != nil {
				return err
			}
			n, err := net.Load(net.PlatformEnvPath)
			if err != nil {
				return err
			}
			return cli.DBCreate(ctx, c.OutOrStdout(), arg, p, s, dns, n, devUID())
		})

	deleteCmd := build("delete <engine:version>", "Remove a DB container (keeps its data)",
		func(ctx context.Context, c *cobra.Command, arg string) error {
			p, s, dns, err := dbDeps()
			if err != nil {
				return err
			}
			return cli.DBDelete(ctx, c.OutOrStdout(), c.InOrStdin(), arg, p, s, dns, assumeYes)
		})
	deleteCmd.Flags().BoolVar(&assumeYes, "yes", false, "Skip the confirmation prompt")

	cmd.AddCommand(
		createCmd,
		deleteCmd,
		build("start <engine:version>", "Start a stopped DB container",
			func(ctx context.Context, c *cobra.Command, arg string) error {
				p, s, dns, err := dbDeps()
				if err != nil {
					return err
				}
				return cli.DBStart(ctx, c.OutOrStdout(), arg, p, s, dns)
			}),
		build("stop <engine:version>", "Stop a running DB container",
			func(ctx context.Context, c *cobra.Command, arg string) error {
				p, s, dns, err := dbDeps()
				if err != nil {
					return err
				}
				return cli.DBStop(ctx, c.OutOrStdout(), arg, p, s, dns)
			}),
	)
	return cmd
}

func dbDeps() (*podman.Client, state.Store, dnsmasq.Manager, error) {
	n, err := net.Load(net.PlatformEnvPath)
	if err != nil {
		return nil, state.Store{}, dnsmasq.Manager{}, err
	}
	p := podman.New()
	return p, state.New(), dnsmasq.New(state.Dir, n, p), nil
}

func projectDeps() (cli.ProjectDeps, error) {
	n, err := net.Load(net.PlatformEnvPath)
	if err != nil {
		return cli.ProjectDeps{}, err
	}
	p := podman.New()
	user := os.Getenv("USER")
	if user == "" {
		user = "user"
	}
	return cli.ProjectDeps{
		Podman:   p,
		State:    state.New(),
		Dnsmasq:  dnsmasq.New(state.Dir, n, p),
		Observer: current.NewObserver(n.VMID(), p),
		Assets:   assets.New(),
		Net:      n,
		DevUser:  user,
		UID:      devUID(),
	}, nil
}

func projectStartCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "start <project>",
		Short: "Start a project",
		Args:  cobra.ExactArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			d, err := projectDeps()
			if err != nil {
				return err
			}
			return cli.ProjectStart(c.Context(), c.OutOrStdout(), args[0], d)
		},
	}
}

func projectStopCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "stop <project>",
		Short: "Stop a project",
		Args:  cobra.ExactArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			d, err := projectDeps()
			if err != nil {
				return err
			}
			return cli.ProjectStop(c.Context(), c.OutOrStdout(), args[0], d)
		},
	}
}

// checkHooksCmd mirrors Swift's `mpd --check-hooks`. Diagnostics are
// warnings, never failures: an orphaned hook simply never fires, and
// refusing to run over one would be worse than the problem.
func checkHooksCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "check-hooks",
		Short: "Cross-reference hook directories against the event catalogue",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, args []string) error {
			hooks.Diagnose(c.ErrOrStderr(), state.Dir)
			return nil
		},
	}
}

func projectDeleteCmd() *cobra.Command {
	var assumeYes bool
	cmd := &cobra.Command{
		Use:   "delete <project>",
		Short: "Delete a project, its database, dataroot and source tree",
		Args:  cobra.ExactArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			d, err := projectDeps()
			if err != nil {
				return err
			}
			return cli.ProjectDelete(c.Context(), c.OutOrStdout(), c.InOrStdin(), args[0], d, assumeYes)
		},
	}
	cmd.Flags().BoolVar(&assumeYes, "yes", false, "Skip the confirmation prompt")
	return cmd
}

func projectConfigureCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "configure <project> [KEY=VALUE ...]",
		Short: "Apply mpd.env changes and reconcile the project",
		Args:  cobra.MinimumNArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			d, err := projectDeps()
			if err != nil {
				return err
			}
			return cli.ProjectConfigure(c.Context(), c.OutOrStdout(), args[0], args[1:], d)
		},
	}
}

func projectCreateCmd() *cobra.Command {
	var opts cli.CreateOptions
	cmd := &cobra.Command{
		Use:   "create <project>",
		Short: "Scaffold a new project",
		Args:  cobra.ExactArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			d, err := projectDeps()
			if err != nil {
				return err
			}
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			return cli.ProjectCreate(c.Context(), c.OutOrStdout(), args[0], opts, d, home)
		},
	}
	cmd.Flags().StringVar(&opts.Type, "type", "", "Project type (default: inferred, else moodle)")
	cmd.Flags().StringVar(&opts.GitRepo, "git-repo", "", "Clone this repository into the project")
	cmd.Flags().StringVar(&opts.GitBranch, "git-branch", "", "Branch to clone")
	cmd.Flags().StringVar(&opts.GitDepth, "git-depth", "", "Shallow-clone depth")
	return cmd
}
