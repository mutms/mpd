// Command mpd is the mpd control plane, run inside the mpd VM.
// Project work is verb-first; VM actions take `--vm-`-prefixed flags.
// See docs/cli-behavior.md.
package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/cli"
	"github.com/mutms/mpd/go/internal/current"
	"github.com/mutms/mpd/go/internal/dnsmasq"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/service"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/vm"
	"github.com/mutms/mpd/go/internal/web"
	"github.com/spf13/cobra"
)

// version is stamped at build time via -ldflags.
var version = "dev"

// projectCommands lists the project verbs for help output.
const projectCommands = `  status     [projectname] [--json]            project details (--json for scripts)
  init       [projectname] [--type=<type>]     scaffold a new project (default type: moodle)
  start      [projectname] [KEY=VALUE ...]     configure + start (e.g. MPD_DB=postgres:18,
                                               MPD_PHP_VERSION=8.4; full set lives in
                                               /srv/projects/<projectname>/mpd.env)
  stop       [projectname]
  reset      [projectname] [--yes]             destroy its DB + data, keep the code;
                                               leaves it not initialised
  delete     <projectname> [--yes]             (alias: rm; never inferred — name it explicitly)
  help       <projectname>                     verb reference for one project

The project name is optional: inside /srv/projects/<name>/ (or any
subdirectory) it defaults to that project.`

// otherCommands lists the read-only queries for help output.
const otherCommands = `  list       [projects|services|infra|dbs|network]  (default: projects; alias: ls)`

// usage is the short form shown when a command is misspelled.
const usage = `Usage:
  mpd <flags>
  mpd <verb> <projectname> [args...]

Project commands:
` + projectCommands

// helpTemplate replaces cobra's default so project verbs and VM flags
// are listed as separate groups.
const helpTemplate = `mpd — Moodle Plugin Development Environment

Usage:
  mpd <flags>
  mpd <verb> <projectname> [args...]

Project commands:
` + projectCommands + `

Other commands:
` + otherCommands + `

Flags:
{{.LocalFlags.FlagUsages}}`

// flags holds every global option.
type flags struct {
	vmSetup   bool
	vmUpgrade bool
	vmStart   bool
	vmStop    bool
	vmRestart bool
	vmStatus  bool
	vmDiag    bool

	dbCreate string
	dbStart  string
	dbStop   string
	dbDelete string

	serviceStart     string
	serviceStop      string
	serviceUninstall string
	servicePurge     string

	web     bool
	control bool
	yes     bool
	debug   bool

	// json is registered on the status command only, not the root.
	json bool
}

func main() {
	// --complete short-circuits before cobra: it runs on every Tab press
	// and must not pay for building the command tree.
	if len(os.Args) >= 3 && os.Args[1] == "--complete" {
		cli.CompleteFromArgs(os.Stdout, os.Args[2:], state.New(), assets.New())
		cli.ExitCompletion()
	}

	var f flags
	root := &cobra.Command{
		Use:           "mpd",
		Short:         "mpd — Moodle Plugin Development Environment",
		Long:          "mpd — Moodle Plugin Development Environment",
		SilenceUsage:  true,
		SilenceErrors: true,
		Args:          cobra.ArbitraryArgs,
		RunE: func(c *cobra.Command, args []string) error {
			return dispatch(c, args, &f)
		},
	}

	// Enables --version/-v; the template prints the bare version string.
	// There is deliberately no `version` subcommand.
	root.Version = version
	root.SetVersionTemplate("{{.Version}}\n")

	// Declaration order, not alphabetical, so the help keeps the groups.
	root.Flags().SortFlags = false

	root.Flags().BoolVar(&f.vmSetup, "vm-setup", false,
		"Idempotent VM setup. Safe to run repeatedly. Adopts the current VM.")
	root.Flags().BoolVar(&f.vmUpgrade, "vm-upgrade", false,
		"Pull and rebuild mpd (plus mudev and the /srv/extra catalogues), then run --vm-setup.")
	root.Flags().BoolVar(&f.vmStart, "vm-start", false,
		"Daily start: start services and restore running projects. No provisioning.")
	root.Flags().BoolVar(&f.vmStop, "vm-stop", false,
		"Graceful stop: fire pre-stop hooks, then power off the VM.")
	root.Flags().BoolVar(&f.vmRestart, "vm-restart", false,
		"Reboot the VM (graceful DB shutdown via the systemd unit; mpd auto-starts on boot).")
	root.Flags().BoolVar(&f.vmStatus, "vm-status", false,
		"Show context-aware status (text output).")
	root.Flags().BoolVar(&f.vmDiag, "vm-diag", false,
		"Probe this VM and report what works: certificates, DNS, routing, TLS, project frontdoor, desktop. Read-only; exits non-zero on failure.")

	root.Flags().StringVar(&f.dbCreate, "db-create", "", "Create (or start) a DB container, e.g. `postgres:17`.")
	root.Flags().StringVar(&f.dbStart, "db-start", "", "Start a stopped DB container `name`.")
	root.Flags().StringVar(&f.dbStop, "db-stop", "", "Stop a running DB container `name`.")
	root.Flags().StringVar(&f.dbDelete, "db-delete", "", "Remove a DB container `name` (prompts unless --yes).")

	root.Flags().StringVar(&f.serviceStart, "service-start", "",
		"Start an extra service `name` (mailpit, adminer, selenium) and keep it autostarting. A project's MPD_REQUIRE_SERVICES starts what it needs on its own.")
	root.Flags().StringVar(&f.serviceStop, "service-stop", "",
		"Stop an extra service `name` and clear its autostart intent; a project that requires it starts it again on `mpd start`.")
	root.Flags().StringVar(&f.serviceUninstall, "service-uninstall", "",
		"Remove an extra service `name`'s container, keeping its data volume.")
	root.Flags().StringVar(&f.servicePurge, "service-purge", "",
		"Remove an extra service `name` AND its data volume.")

	root.Flags().BoolVar(&f.web, "web", false,
		"Run the status web server in the foreground (systemd: mpd-web.service).")

	root.Flags().BoolVar(&f.yes, "yes", false, "Skip confirmation prompts (for scripted use).")
	root.Flags().BoolVar(&f.debug, "debug", false, "Print debug information.")

	root.SetHelpTemplate(helpTemplate)
	// mpd ships its own completion shims under assets/completions/.
	root.CompletionOptions.DisableDefaultCmd = true

	root.AddCommand(listCmd())
	root.AddCommand(projectVerbCmds(&f)...)
	root.SetHelpCommand(helpCmd())

	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}

// dispatch acts on the first global flag given; with none it shows status.
func dispatch(c *cobra.Command, args []string, f *flags) error {
	ctx := c.Context()
	out := c.OutOrStdout()

	// A leftover positional is a verb typo or an unknown name; say so
	// instead of silently printing status.
	if len(args) > 0 {
		return fmt.Errorf("unknown command %q\n\n%s", args[0], usage)
	}

	switch {
	case f.web:
		// Long-running: blocks until the context is cancelled.
		n, err := net.Current()
		if err != nil {
			return err
		}
		p := podman.New()
		return web.Serve(ctx, out, web.Deps{
			Net:        n,
			Podman:     p,
			State:      state.New(),
			Observer:   current.NewObserver(n.VMID(), p),
			Assets:     assets.New(),
			UnitActive: vm.UnitActive,
			Version:    version,
		})
	case f.vmSetup:
		return withLock(ctx, out, state.New(), func() error { return cli.Setup(ctx, out) })
	case f.vmUpgrade:
		// No lock: the `mpd --vm-setup` child it spawns takes the lock
		// itself and would block forever on one held here.
		return cli.Upgrade(ctx, out, state.New())
	case f.vmStart:
		d, err := projectDeps()
		if err != nil {
			return err
		}
		return withLock(ctx, out, d.State, func() error { return cli.Start(ctx, out, d, state.Dir) })
	case f.vmStop:
		d, err := projectDeps()
		if err != nil {
			return err
		}
		return withLock(ctx, out, d.State, func() error { return cli.Stop(ctx, out, d, state.Dir) })
	case f.vmRestart:
		return withLock(ctx, out, state.New(), func() error { return cli.Restart(ctx, out, state.Dir) })
	case f.vmDiag:
		// No lock: probes are read-only and must run while another
		// command holds the lock.
		n, err := net.Current()
		if err != nil {
			return err
		}
		p := podman.New()
		return cli.Diag(ctx, out, cli.DiagDeps{
			Net:      n,
			Podman:   p,
			State:    state.New(),
			Observer: current.NewObserver(n.VMID(), p),
			Version:  version,
		})
	}

	if name := firstNonEmpty(f.dbCreate, f.dbStart, f.dbStop, f.dbDelete); name != "" {
		return dbAction(ctx, out, c, f, name)
	}
	if name := firstNonEmpty(f.serviceStart, f.serviceStop,
		f.serviceUninstall, f.servicePurge); name != "" {
		return serviceAction(ctx, out, f, name)
	}

	// No flag given (or only --vm-status): show status.
	n, err := net.Current()
	if err != nil {
		return err
	}
	cli.Status(ctx, out, state.New(), podman.New(), n, devUID())
	return nil
}

// withLock runs fn under mpd's exclusive mutation lock. flock is per
// open file description, so the lock is taken only here at the boundary;
// a second acquire in the same process would block forever. Read-only
// paths skip it — atomic renames keep readers safe. See state.Store.Acquire.
func withLock(ctx context.Context, out io.Writer, s state.Store, fn func() error) error {
	release, err := s.Acquire(ctx, out)
	if err != nil {
		return err
	}
	defer release()
	return fn()
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

func serviceAction(ctx context.Context, out interface{ Write([]byte) (int, error) },
	f *flags, name string) error {

	n, p, s, dns, _, err := vmDeps()
	if err != nil {
		return err
	}
	vmIP := vm.PrimaryIP()
	return withLock(ctx, out, s, func() error {
		switch {
		case f.serviceStart != "":
			return cli.ServiceStart(ctx, out, name, p, s, dns, n, vmIP)
		case f.serviceStop != "":
			return cli.ServiceStop(ctx, out, name, p, s, dns, n, vmIP)
		case f.serviceUninstall != "":
			return cli.ServiceUninstall(ctx, out, name, p, s, dns, n, vmIP)
		default:
			return cli.ServicePurge(ctx, out, name, p, s, dns, n, vmIP)
		}
	})
}

func dbAction(ctx context.Context, out interface{ Write([]byte) (int, error) },
	c *cobra.Command, f *flags, name string) error {

	n, p, s, dns, _, err := vmDeps()
	if err != nil {
		return err
	}
	return withLock(ctx, out, s, func() error {
		switch {
		case f.dbCreate != "":
			return cli.DBCreate(ctx, out, name, p, s, dns, n, devUID())
		case f.dbStart != "":
			return cli.DBStart(ctx, out, name, p, s, dns, n)
		case f.dbStop != "":
			return cli.DBStop(ctx, out, name, p, s, dns, n)
		default:
			return cli.DBDelete(ctx, out, c.InOrStdin(), name, p, s, dns, n, f.yes)
		}
	})
}

// helpCmd replaces cobra's built-in help: `mpd help <project>` prints
// that project's verb reference; with no argument it shows normal help.
func helpCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "help [project]",
		Short: "Show the verb reference for a project, or general help",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			if len(args) == 0 {
				return c.Root().Help()
			}
			n, err := net.Current()
			if err != nil {
				return err
			}
			cli.ShowHelp(c.OutOrStdout(), args[0], n)
			return nil
		},
	}
}

// listCmd is the read-only inspection surface; `network` sits here so
// everything a developer inspects is under one command.
func listCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:       "list [projects|services|infra|dbs|network]",
		Aliases:   []string{"ls"},
		Short:     "List entities — projects (default), extra services, VM infra, DB containers, or this VM's addressing",
		ValidArgs: []string{"projects", "services", "infra", "dbs", "network"},
		Args:      cobra.MatchAll(cobra.MaximumNArgs(1), cobra.OnlyValidArgs),
		RunE: func(cmd *cobra.Command, args []string) error {
			what := "projects"
			if len(args) == 1 {
				what = args[0]
			}
			n, err := net.Current()
			if err != nil {
				return err
			}
			out := cmd.OutOrStdout()
			ctx := cmd.Context()
			p, s := podman.New(), state.New()

			switch what {
			case "projects":
				cli.ListProjects(out, s)
			case "services":
				cli.ListServices(ctx, out, n, p, s)
			case "infra":
				cli.ListInfra(ctx, out, n, vm.UnitActive)
			case "dbs":
				cli.ListDatabases(ctx, out, n, p, s)
			case "network":
				fmt.Fprintf(out, "vm id       %s\n", n.VMID())
				fmt.Fprintf(out, "zone        %s\n", n.Zone())
				fmt.Fprintf(out, "subnet      %s\n", n.Subnet())
				// The VM's own address, not on the container subnet.
				// Empty on sandbox VMs, which take a DHCP lease.
				host, _ := os.Hostname()
				if vmIP := vm.PrimaryIP(); vmIP != "" {
					fmt.Fprintf(out, "vm          %s (ssh %s, %s)\n",
						vmIP, host, n.VMServiceRecord())
				} else {
					fmt.Fprintf(out, "vm          ssh %s (address is DHCP)\n", host)
				}
				fmt.Fprintf(out, "gateway     %s\n", n.Gateway())
				fmt.Fprintf(out, "dnsmasq     %s (the VM itself: resolver for .test)\n", n.Gateway())
				fmt.Fprintf(out, "portal      %s (the VM itself: mpd --web behind caddy)\n", n.Gateway())
				fmt.Fprintf(out, "projects    %s (the VM itself: project vhosts behind caddy)\n", n.IP(net.HostProjects))
				fmt.Fprintf(out, "databases   %s-%d\n", n.IP(net.DBHostFirst), net.DBHostLast)
				for _, svc := range service.All() {
					fmt.Fprintf(out, "%-12s%s\n", svc.Name, svc.IP(n))
				}
			}
			return nil
		},
	}
	return cmd
}

// projectVerbCmds builds one cobra command per project verb. Verbs are
// registered on the root, so a project may never be named after one
// (see cli.ProjectVerbs).
func projectVerbCmds(f *flags) []*cobra.Command {
	verbs := []*cobra.Command{}

	// lock says whether the verb mutates. Explicit, because getting it
	// wrong is silent in both directions.
	build := func(use, short string, lock bool,
		run func(context.Context, *cobra.Command, string, cli.ProjectDeps) error) *cobra.Command {

		verb, _, _ := strings.Cut(use, " ")
		return &cobra.Command{
			Use:   use,
			Short: short,
			Args:  cobra.MaximumNArgs(1),
			RunE: func(c *cobra.Command, args []string) error {
				name, err := cli.ProjectArg(verb, args)
				if err != nil {
					return err
				}
				d, err := projectDeps()
				if err != nil {
					return err
				}
				if !lock {
					return run(c.Context(), c, name, d)
				}
				return withLock(c.Context(), c.OutOrStdout(), d.State, func() error {
					return run(c.Context(), c, name, d)
				})
			},
		}
	}
	simple := func(use, short string, run func(context.Context, *cobra.Command, string, cli.ProjectDeps) error) *cobra.Command {
		return build(use, short, false, run)
	}
	mutating := func(use, short string, run func(context.Context, *cobra.Command, string, cli.ProjectDeps) error) *cobra.Command {
		return build(use, short, true, run)
	}

	// start takes KEY=VALUE settings besides the optional project name,
	// so it parses its args with SplitStartArgs rather than ProjectArg.
	startCmd := &cobra.Command{
		Use:   "start [project] [KEY=VALUE ...]",
		Short: "Configure and start a project (default: the one you are in)",
		Args:  cobra.ArbitraryArgs,
		RunE: func(c *cobra.Command, args []string) error {
			name, settings, err := cli.SplitStartArgs(args)
			if err != nil {
				return err
			}
			d, err := projectDeps()
			if err != nil {
				return err
			}
			return withLock(c.Context(), c.OutOrStdout(), d.State, func() error {
				return cli.ProjectStart(c.Context(), c.OutOrStdout(), name, settings, d)
			})
		},
	}
	verbs = append(verbs,
		startCmd,
		mutating("stop [project]", "Stop a project (default: the one you are in)",
			func(ctx context.Context, c *cobra.Command, name string, d cli.ProjectDeps) error {
				return cli.ProjectStop(ctx, c.OutOrStdout(), name, d)
			}),
	)

	// --json is what tools read instead of opening /srv/meta;
	// the flag rides along when status is forwarded over the control socket.
	statusCmd := simple("status [project]", "Show project details (default: the one you are in)",
		func(ctx context.Context, c *cobra.Command, name string, d cli.ProjectDeps) error {
			if f.json {
				return cli.ShowProjectJSON(ctx, c.OutOrStdout(), name, d.State, d.Podman, d.Observer, d.Net)
			}
			cli.ShowProject(c.OutOrStdout(), name, d.State, d.Net)
			return nil
		})
	statusCmd.Flags().BoolVar(&f.json, "json", false, "print the project's status as JSON")
	verbs = append(verbs, statusCmd)

	// reset infers from the working directory, unlike delete: it keeps
	// the source tree, so the inferred directory still exists afterwards.
	resetCmd := mutating("reset [project]",
		"Reset a project: destroy its data, keep the code (default: the one you are in)",
		func(ctx context.Context, c *cobra.Command, name string, d cli.ProjectDeps) error {
			return cli.ProjectReset(ctx, c.OutOrStdout(), c.InOrStdin(), name, d, f.yes)
		})
	resetCmd.Flags().BoolVar(&f.yes, "yes", false, "Skip the confirmation prompt")
	verbs = append(verbs, resetCmd)

	// delete never infers its project: it removes the source tree, which
	// would routinely be the directory the caller is standing in.
	deleteCmd := &cobra.Command{
		Use:     "delete <project>",
		Aliases: []string{"rm"},
		Short:   "Delete a project, its database, dataroot and source tree",
		Args:    cobra.MaximumNArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			if len(args) == 0 {
				name, inProject := cli.ProjectNameFromCwd()
				if inProject {
					return fmt.Errorf("mpd delete: name the project explicitly — `mpd delete %s`.\n"+
						"delete is never inferred from the working directory: it removes that\n"+
						"directory, and you are standing in it.", name)
				}
				return fmt.Errorf("mpd delete: which project? Usage: mpd delete <project> [--yes]")
			}
			d, err := projectDeps()
			if err != nil {
				return err
			}
			return withLock(c.Context(), c.OutOrStdout(), d.State, func() error {
				return cli.ProjectDelete(c.Context(), c.OutOrStdout(), c.InOrStdin(), args[0], d, f.yes)
			})
		},
	}
	deleteCmd.Flags().BoolVar(&f.yes, "yes", false, "Skip the confirmation prompt")

	var opts cli.CreateOptions
	initCmd := &cobra.Command{
		Use:   "init [project]",
		Short: "Scaffold a new project (default: the directory you are in)",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			name, err := cli.ProjectArg("init", args)
			if err != nil {
				return err
			}
			d, err := projectDeps()
			if err != nil {
				return err
			}
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			return withLock(c.Context(), c.OutOrStdout(), d.State, func() error {
				return cli.ProjectCreate(c.Context(), c.OutOrStdout(), name, opts, d, home)
			})
		},
	}
	initCmd.Flags().StringVar(&opts.Type, "type", "", "Project type (default: inferred, else moodle)")

	verbs = append(verbs, deleteCmd, initCmd)

	return verbs
}

// devUID is the uid mpd writes data-volume files as.
func devUID() string { return strconv.Itoa(os.Getuid()) }

// devUser is the account name project scripts and hooks run as.
func devUser() string {
	if id := vm.DetectIdentity(); id.User != "" {
		return id.User
	}
	if u := strings.TrimSpace(os.Getenv("USER")); u != "" {
		return u
	}
	return "user"
}

func vmDeps() (net.Net, *podman.Client, state.Store, dnsmasq.Manager, current.Observer, error) {
	n, err := net.Current()
	if err != nil {
		return net.Net{}, nil, state.Store{}, dnsmasq.Manager{}, current.Observer{}, err
	}
	p := podman.New()
	s := state.New()
	return n, p, s, dnsmasq.New(n, p, s), current.NewObserver(n.VMID(), p), nil
}

func projectDeps() (cli.ProjectDeps, error) {
	n, err := net.Current()
	if err != nil {
		return cli.ProjectDeps{}, err
	}
	p := podman.New()
	s := state.New()
	return cli.ProjectDeps{
		Podman:   p,
		State:    s,
		Dnsmasq:  dnsmasq.New(n, p, s),
		Observer: current.NewObserver(n.VMID(), p),
		Assets:   assets.New(),
		Net:      n,
		DevUser:  devUser(),
		UID:      devUID(),
	}, nil
}
