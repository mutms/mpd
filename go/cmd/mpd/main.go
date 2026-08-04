// Command mpd is the mpd control plane, run inside the mpd VM.
//
// Two grammars, deliberately:
//
//   - Project work is verb-first — `mpd start myproject`, `mpd create
//     myproject --type=moodle`. It reads like git and is what a developer
//     types dozens of times a day.
//   - Everything that acts on the VM or its infrastructure is a flag —
//     `mpd --vm-setup`, `mpd --runtime-create=php`, `mpd --db-start`.
//
// The split exists so `mpd stop myproject` and `mpd --vm-stop` can never
// be confused for each other. A bare `mpd stop` acting on the VM next to
// `mpd stop <project>` acting on a project is exactly the ambiguity the
// `--vm-` prefix removes.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/cli"
	"github.com/mutms/mpd/go/internal/control"
	"github.com/mutms/mpd/go/internal/current"
	"github.com/mutms/mpd/go/internal/dnsmasq"
	"github.com/mutms/mpd/go/internal/hooks"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/vm"
	"github.com/mutms/mpd/go/internal/web"
	"github.com/spf13/cobra"
)

// version is stamped at build time via -ldflags.
var version = "dev"

// projectCommands is the verb-first half of the CLI: everything that
// acts on one project.
const projectCommands = `  show       [projectname]                     project details
  create     [projectname] [--type=<type>]     (default type: moodle)
  configure  [projectname] [KEY=VALUE ...]     (e.g. MPD_DB=postgres:18, MPD_PHP_VERSION=8.4;
                                               full set lives in /srv/projects/<projectname>/mpd.env)
  start      [projectname]
  stop       [projectname]
  reset      [projectname] [--yes]             destroy its DB + data, keep the code;
                                               leaves it not-configured
  delete     <projectname> [--yes]             (never inferred — name it explicitly)
  help       <projectname>                     verb reference for one project
  run        <command> [args...]               run a command in the runtime of the
                                               project you are standing in

The project name is optional: inside /srv/projects/<name>/ (or any
subdirectory) it defaults to that project.`

// otherCommands are the read-only queries that are neither a project
// verb nor a VM action.
const otherCommands = `  list       [projects|runtimes|services|dbs|network]  (default: projects)
  version                                      print the mpd version`

// usage is the short form shown when a command is misspelled.
const usage = `Usage:
  mpd <flags>
  mpd <verb> <projectname> [args...]

Project commands:
` + projectCommands

// helpTemplate replaces cobra's default, which lists every command in one
// undifferentiated block — including its own `completion` and `help`
// entries — and buries the flags that are most of mpd's surface. The two
// halves of the CLI are named instead: project verbs, then VM flags.
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

// flags holds every global option. One struct rather than package-level
// vars so the dispatch below reads as a single decision.
type flags struct {
	vmSetup   bool
	vmUpgrade bool
	vmStart   bool
	vmStop    bool
	vmRestart bool
	vmStatus  bool

	runtimeCreate string
	runtimeStart  string
	runtimeStop   string
	runtimeDelete string
	runtimeShow   string

	dbCreate string
	dbStart  string
	dbStop   string
	dbDelete string

	checkHooks bool
	web        bool
	control    bool
	yes        bool
	debug      bool
}

func main() {
	// `--complete` short-circuits before cobra: it is invoked on every Tab
	// press by the shell shims, must never fail, and must not pay for
	// building the command tree.
	if len(os.Args) >= 3 && os.Args[1] == "--complete" {
		cli.CompleteFromArgs(os.Stdout, os.Args[2:], state.New(), assets.New())
		cli.ExitCompletion()
	}

	// Inside a runtime container there is no control plane to run against:
	// /var/lib/mpd/conf and /var/lib/mpd/state are deliberately not
	// mounted, and there is no podman socket. So the command goes to the
	// VM, which runs it and writes back through this terminal.
	//
	// Before cobra, because building the command tree here would only
	// produce handlers that cannot work — every one of them starts by
	// resolving the VM's identity. Forwarding the raw argv also means the
	// VM parses it with its own command tree, which is the only one that
	// should decide what a verb means.
	if _, inRuntime := control.RuntimeName(); inRuntime && !runsLocallyInRuntime(os.Args[1:]) {
		code, err := control.Forward(os.Args[1:])
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
		}
		os.Exit(code)
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

	// Declaration order, not alphabetical: the help then reads as the
	// groups below — VM lifecycle, runtimes, databases, modifiers —
	// instead of interleaving them.
	root.Flags().SortFlags = false

	// VM lifecycle. The `--vm-` prefix names what they act on, so none of
	// them can be mistaken for the project verb of the same name.
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

	root.Flags().StringVar(&f.runtimeCreate, "runtime-create", "", "Provision a new runtime named `name`.")
	root.Flags().StringVar(&f.runtimeStart, "runtime-start", "", "Start a stopped runtime `name`.")
	root.Flags().StringVar(&f.runtimeStop, "runtime-stop", "", "Stop a running runtime `name`.")
	root.Flags().StringVar(&f.runtimeDelete, "runtime-delete", "", "Stop and remove runtime `name` (prompts unless --yes).")
	root.Flags().StringVar(&f.runtimeShow, "runtime", "", "Show runtime `name` and its projects.")

	root.Flags().StringVar(&f.dbCreate, "db-create", "", "Create (or start) a DB container, e.g. `postgres:17`.")
	root.Flags().StringVar(&f.dbStart, "db-start", "", "Start a stopped DB container `name`.")
	root.Flags().StringVar(&f.dbStop, "db-stop", "", "Stop a running DB container `name`.")
	root.Flags().StringVar(&f.dbDelete, "db-delete", "", "Remove a DB container `name` (prompts unless --yes).")

	root.Flags().BoolVar(&f.web, "web", false,
		"Run the status web server in the foreground (systemd: mpd-web.service).")
	root.Flags().BoolVar(&f.control, "control", false,
		"Serve project commands sent from inside runtimes (systemd: mpd-control.service).")

	root.Flags().BoolVar(&f.checkHooks, "check-hooks", false,
		"Cross-reference hook directories against the event catalogue. Also runs at the end of --vm-setup.")
	root.Flags().BoolVar(&f.yes, "yes", false, "Skip confirmation prompts (for scripted use).")
	root.Flags().BoolVar(&f.debug, "debug", false, "Print debug information.")

	root.SetHelpTemplate(helpTemplate)
	// cobra's generated `completion` command is noise here: mpd ships its
	// own shims under assets/completions/, installed by --vm-setup.
	root.CompletionOptions.DisableDefaultCmd = true

	root.AddCommand(versionCmd(), listCmd())
	root.AddCommand(projectVerbCmds(&f)...)
	root.SetHelpCommand(helpCmd())

	if err := root.Execute(); err != nil {
		// A forwarded command's exit status is passed through untouched
		// and silently: the child already reported whatever failed, and
		// `mpd run` adding its own line would corrupt piped output.
		var exit cli.ExitError
		if errors.As(err, &exit) {
			os.Exit(exit.Code)
		}
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}

// dispatch runs whichever global flag was given.
//
// Order matches the flag groups above; at most one flag is acted on, and
// a bare `mpd` with no flags falls through to status — a more useful
// answer for someone who just typed `mpd` than usage text would be.
func dispatch(c *cobra.Command, args []string, f *flags) error {
	ctx := c.Context()
	out := c.OutOrStdout()

	// A leftover positional here is a project verb typo or an unknown
	// name; saying so beats silently printing status.
	if len(args) > 0 {
		return fmt.Errorf("unknown command %q\n\n%s", args[0], usage)
	}

	switch {
	case f.web:
		// Long-running, unlike every other flag here: the process is the
		// service, so it blocks until the context is cancelled.
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
		})
	case f.control:
		// Long-running, like --web. Deliberately does NOT take the state
		// lock: each request spawns a child mpd that takes it itself, and a
		// lock held here would be a different file description that the
		// child would then wait on forever.
		//
		// A socket for every runtime the assets tree defines, not just the
		// provisioned ones. Binding up front means a runtime created later
		// already has its endpoint, so nothing has to reconcile sockets
		// against runtime lifecycle — and a socket whose runtime does not
		// exist is simply one nothing ever connects to.
		a := assets.New()
		runtimes := a.RuntimeNames()
		if err := control.PruneSockets(runtimes); err != nil {
			return err
		}
		return control.Serve(ctx, out, runtimes, control.RunDir, state.New(), a)
	case f.vmSetup:
		return withLock(ctx, out, state.New(), func() error { return cli.Setup(ctx, out) })
	case f.vmUpgrade:
		return withLock(ctx, out, state.New(), func() error { return cli.Upgrade(ctx, out) })
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
	case f.checkHooks:
		hooks.Diagnose(c.ErrOrStderr(), state.Dir)
		return nil
	}

	if name := firstNonEmpty(f.runtimeCreate, f.runtimeStart, f.runtimeStop,
		f.runtimeDelete, f.runtimeShow); name != "" {
		return runtimeAction(ctx, out, c, f, name)
	}
	if name := firstNonEmpty(f.dbCreate, f.dbStart, f.dbStop, f.dbDelete); name != "" {
		return dbAction(ctx, out, c, f, name)
	}

	// No flag given (or only --vm-status): show status.
	n, err := net.Current()
	if err != nil {
		return err
	}
	cli.Status(ctx, out, state.New(), podman.New(), n, devUID())
	return nil
}

// runsLocallyInRuntime reports whether a command should be answered inside
// the runtime instead of forwarded to the VM.
//
// Only things that are true of the binary itself. `version` reports the
// build of the binary being asked, and /opt/mpd is the same checkout on
// both sides, so answering locally is both correct and faster. Everything
// else needs state, podman or the network, none of which exist here.
func runsLocallyInRuntime(args []string) bool {
	if len(args) == 0 {
		return false
	}
	switch args[0] {
	case "version", "--version", "-v":
		return true
	}
	return false
}

// withLock runs fn under mpd's exclusive mutation lock.
//
// Every mutating entry point goes through here and nothing else does.
// flock is per open file description, so a second acquire inside the same
// process blocks on itself forever — which is why the lock is taken in
// this file, at the boundary, and never from inside a cli handler. A
// handler that needs it already has it. See state.Store.Acquire.
//
// Read-only paths (show, list, status, --vm-status) are deliberately
// absent: the atomic rename in writeJSON means a reader sees either the
// old file or the new one, so blocking them behind a long create would
// cost real waiting to prevent nothing.
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

func runtimeAction(ctx context.Context, out interface{ Write([]byte) (int, error) },
	c *cobra.Command, f *flags, name string) error {

	n, p, s, dns, o, err := runtimeDeps()
	if err != nil {
		return err
	}
	// --runtime-show reads; everything else here mutates.
	if f.runtimeShow != "" {
		return cli.ShowRuntime(ctx, out, name, s, p, o, n)
	}
	return withLock(ctx, out, s, func() error {
		switch {
		case f.runtimeCreate != "":
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			return cli.RuntimeCreate(ctx, out, name, p, s, dns, o, n, assets.New(), devUser(), devUID(), home)
		case f.runtimeStart != "":
			return cli.RuntimeStart(ctx, out, name, p, s, dns, o, n, devUser(), devUID())
		case f.runtimeStop != "":
			return cli.RuntimeStop(ctx, out, name, p, s, dns, o)
		case f.runtimeDelete != "":
			return cli.RuntimeDelete(ctx, out, c.InOrStdin(), name, p, s, dns, o, devUser(), f.yes)
		default:
			return cli.ShowRuntime(ctx, out, name, s, p, o, n)
		}
	})
}

func dbAction(ctx context.Context, out interface{ Write([]byte) (int, error) },
	c *cobra.Command, f *flags, name string) error {

	p, s, dns, err := dbDeps()
	if err != nil {
		return err
	}
	// Every db action mutates — there is no --db-show.
	return withLock(ctx, out, s, func() error {
		switch {
		case f.dbCreate != "":
			n, err := net.Current()
			if err != nil {
				return err
			}
			return cli.DBCreate(ctx, out, name, p, s, dns, n, devUID())
		case f.dbStart != "":
			return cli.DBStart(ctx, out, name, p, s, dns)
		case f.dbStop != "":
			return cli.DBStop(ctx, out, name, p, s, dns)
		default:
			return cli.DBDelete(ctx, out, c.InOrStdin(), name, p, s, dns, f.yes)
		}
	})
}

// helpCmd replaces cobra's built-in `help`, because `mpd help
// <project>` is a project verb: it prints that project's verb reference.
// With no argument it falls back to the normal command help, so `mpd
// help` still does what every CLI's `help` does.
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

// listCmd is the read-only inspection surface. `network` sits here with
// the collections rather than as its own top-level verb: everything a
// developer inspects is then under one command, and `mpd list <TAB>`
// offers it — a top-level `mpd net` was findable only by knowing it
// existed.
//
// It reports this VM's addressing, which is the diagnostic to reach for
// when a name resolves to the wrong place.
func listCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:       "list [projects|runtimes|services|dbs|network]",
		Short:     "List entities — projects (default), runtimes, services, DB containers, or this VM's addressing",
		ValidArgs: []string{"projects", "runtimes", "services", "dbs", "network"},
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
			p, s, a := podman.New(), state.New(), assets.New()

			switch what {
			case "projects":
				cli.ListProjects(ctx, out, s, current.NewObserver(n.VMID(), p))
			case "runtimes":
				cli.ListRuntimes(ctx, out, n, p, s, a)
			case "services":
				cli.ListServices(ctx, out, n, p, vm.UnitActive)
			case "dbs":
				cli.ListDatabases(ctx, out, n, p, s)
			case "network":
				fmt.Fprintf(out, "vm id       %s\n", n.VMID())
				fmt.Fprintf(out, "zone        %s\n", n.Zone())
				fmt.Fprintf(out, "subnet      %s\n", n.Subnet())
				// The VM's own address, which is the one NOT on the
				// container subnet — and the one you need to get back in.
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
				fmt.Fprintf(out, "adminer     %s\n", n.IP(net.HostAdminer))
			}
			return nil
		},
	}
	return cmd
}

// projectVerbCmds builds the verb-first project grammar, one cobra
// command per verb, each taking the project name as its first argument:
// `mpd start myproject`.
//
// They are registered on the root command, so the verb is what cobra
// resolves — which is why a project may never be named after one. The
// verb set is reserved at create time (see cli.ProjectVerbs).
func projectVerbCmds(f *flags) []*cobra.Command {
	verbs := []*cobra.Command{}

	// The project argument is optional throughout: omitted, it is the
	// project whose directory the caller is standing in (cli.ProjectArg).
	//
	// lock says whether the verb mutates. Passed explicitly rather than
	// inferred, because getting it wrong is silent in both directions: a
	// mutating verb without the lock races, and a read-only verb with it
	// waits for no reason.
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

	verbs = append(verbs,
		mutating("start [project]", "Start a project (default: the one you are in)",
			func(ctx context.Context, c *cobra.Command, name string, d cli.ProjectDeps) error {
				return cli.ProjectStart(ctx, c.OutOrStdout(), name, d)
			}),
		mutating("stop [project]", "Stop a project (default: the one you are in)",
			func(ctx context.Context, c *cobra.Command, name string, d cli.ProjectDeps) error {
				return cli.ProjectStop(ctx, c.OutOrStdout(), name, d)
			}),
		simple("show [project]", "Show project details (default: the one you are in)",
			func(ctx context.Context, c *cobra.Command, name string, d cli.ProjectDeps) error {
				cli.ShowProject(ctx, c.OutOrStdout(), name, d.State, d.Podman, d.Observer, d.Net, d.UID)
				return nil
			}),
	)

	// reset DOES infer from the working directory, unlike delete. The reason
	// delete refuses — it removes the directory you are standing in — does
	// not apply here: reset keeps the source tree, so the inferred project
	// is still a directory that exists afterwards. The typed-name prompt is
	// what guards the destructive part.
	resetCmd := mutating("reset [project]",
		"Reset a project: destroy its data, keep the code (default: the one you are in)",
		func(ctx context.Context, c *cobra.Command, name string, d cli.ProjectDeps) error {
			return cli.ProjectReset(ctx, c.OutOrStdout(), c.InOrStdin(), name, d, f.yes)
		})
	resetCmd.Flags().BoolVar(&f.yes, "yes", false, "Skip the confirmation prompt")
	verbs = append(verbs, resetCmd)

	// The one verb that does NOT infer its project from the working
	// directory: it removes the source tree, so the inferred answer would
	// routinely be the directory the caller is standing in. Deleting that
	// by omission is too easy; naming it is one word.
	deleteCmd := &cobra.Command{
		Use:   "delete <project>",
		Short: "Delete a project, its database, dataroot and source tree",
		Args:  cobra.MaximumNArgs(1),
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

	configureCmd := &cobra.Command{
		Use:   "configure [project] [KEY=VALUE ...]",
		Short: "Apply mpd.env changes and reconcile the project",
		Args:  cobra.ArbitraryArgs,
		RunE: func(c *cobra.Command, args []string) error {
			name, settings, err := cli.SplitConfigureArgs(args)
			if err != nil {
				return err
			}
			d, err := projectDeps()
			if err != nil {
				return err
			}
			return withLock(c.Context(), c.OutOrStdout(), d.State, func() error {
				return cli.ProjectConfigure(c.Context(), c.OutOrStdout(), name, settings, d)
			})
		},
	}

	var opts cli.CreateOptions
	createCmd := &cobra.Command{
		Use:   "create [project]",
		Short: "Scaffold a new project (default: the directory you are in)",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			name, err := cli.ProjectArg("create", args)
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
	createCmd.Flags().StringVar(&opts.Type, "type", "", "Project type (default: inferred, else moodle)")

	runCmd := &cobra.Command{
		Use:   "run [--] <command> [args...]",
		Short: "Run a command in the runtime of the project you are in",
		// The only verb whose second argument is not a project: the
		// project comes from the working directory, everything after
		// `run` is the command to forward.
		Args:               cobra.MinimumNArgs(1),
		DisableFlagParsing: true,
		RunE: func(c *cobra.Command, args []string) error {
			d, err := projectDeps()
			if err != nil {
				return err
			}
			return cli.Run(c.Context(), c.OutOrStdout(), d, args)
		},
	}

	verbs = append(verbs, deleteCmd, configureCmd, createCmd, runCmd)

	return verbs
}

// devUID is the uid volume execs run as, so files written to the data
// volume come out owned by the runtime user.
func devUID() string { return strconv.Itoa(os.Getuid()) }

// devUser is the account name project scripts run as inside a runtime.
func devUser() string {
	if id := vm.DetectIdentity(); id.User != "" {
		return id.User
	}
	if u := strings.TrimSpace(os.Getenv("USER")); u != "" {
		return u
	}
	return "user"
}

func runtimeDeps() (net.Net, *podman.Client, state.Store, dnsmasq.Manager, current.Observer, error) {
	n, err := net.Current()
	if err != nil {
		return net.Net{}, nil, state.Store{}, dnsmasq.Manager{}, current.Observer{}, err
	}
	p := podman.New()
	return n, p, state.New(), dnsmasq.New(state.Dir, n, p), current.NewObserver(n.VMID(), p), nil
}

func dbDeps() (*podman.Client, state.Store, dnsmasq.Manager, error) {
	n, err := net.Current()
	if err != nil {
		return nil, state.Store{}, dnsmasq.Manager{}, err
	}
	p := podman.New()
	return p, state.New(), dnsmasq.New(state.Dir, n, p), nil
}

func projectDeps() (cli.ProjectDeps, error) {
	n, err := net.Current()
	if err != nil {
		return cli.ProjectDeps{}, err
	}
	p := podman.New()
	return cli.ProjectDeps{
		Podman:   p,
		State:    state.New(),
		Dnsmasq:  dnsmasq.New(state.Dir, n, p),
		Observer: current.NewObserver(n.VMID(), p),
		Assets:   assets.New(),
		Net:      n,
		DevUser:  devUser(),
		UID:      devUID(),
	}, nil
}
