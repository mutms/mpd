// mpd — CLI entry point
// Defines GlobalCommand (ArgumentParser root for all --flags), ProjectCommand (project dispatch), and main().
// Public form: `mpd <verb> <project> [args...]` (verb-first, like `git clone <repo>`).
// Internally normalised to hidden ArgumentParser subcommands (`project <verb> <project>`).

import ArgumentParser
import Foundation

// Shell completions are dynamic — `mpd --complete <cword> <words>` returns
// candidates by inspecting state + assets at completion time. Shell-side
// shims under `assets/completions/` only forward to that. Adding a new flag
// or verb generally needs the corresponding case in `mpd/CLI/Complete.swift`.

/// Verbs accepted as the first positional token. Reserved as project names
/// (see `ProjectLifecycle.create`) so a project can never collide with a
/// verb.
let projectVerbs: Set<String> = ["show", "help", "create", "configure", "start", "stop", "delete"]

private func normalizeEntryArgs(_ args: [String]) -> [String] {
    guard let first = args.first, !first.hasPrefix("-") else {
        return args
    }

    // Preserve explicit internal usage (the `project` ArgumentParser subcommand).
    if first == "project" {
        return args
    }

    // Verb-first form: `mpd <verb> <project> [args...]` →
    //                  `mpd project <verb> <project> -- [args...]`
    guard projectVerbs.contains(first) else {
        // Not a verb and not a flag — let ArgumentParser surface a usage error.
        return args
    }

    let verb = first
    let rest = Array(args.dropFirst())
    guard let project = rest.first else {
        // `mpd <verb>` with no project name — let ArgumentParser surface
        // "missing argument" with the usage hint.
        return args
    }

    // Insert `--` so ArgumentParser's captureForPassthrough hands per-verb
    // flags through verbatim instead of resolving them against
    // GlobalCommand's inherited flags (e.g. `--yes`, which is both a global
    // modifier and a verb flag for `delete`).
    let verbArgs = Array(rest.dropFirst())
    if verbArgs.isEmpty {
        return ["project", verb, project]
    }
    return ["project", verb, project, "--"] + verbArgs
}

private func enforceNonRootExecution() {
    if geteuid() == 0 {
        errPrint("mpd must run as a regular user, not as root.")
        errPrint("Current execution environment: \(Mpd.label)")
        errPrint("Re-run without sudo.")
        exit(1)
    }
}

private func enforceExpectedExecutableLocation() {
    let expected = Mpd.expectedExecutablePath
    let expectedPath = URL(fileURLWithPath: expected)
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
    let fm = FileManager.default

    // Beginner-friendly preflight: ensure the fixed source checkout exists.
    if !fm.fileExists(atPath: Mpd.mpdDir) {
        errPrint("mpd source checkout not found at expected path:")
        errPrint("  \(Mpd.mpdDir)")
        errPrint("Clone it there and build first:")
        errPrint("  git clone https://github.com/mutms/mpd.git \(Mpd.mpdDir)")
        errPrint("  \(Mpd.recommendedBuildCommand)")
        errPrint("  \(Mpd.pathExportHint)")
        exit(1)
    }

    let actualRaw = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
    let actualPath = URL(fileURLWithPath: actualRaw, relativeTo: nil)
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path

    guard actualPath == expectedPath else {
        errPrint("Unsupported mpd executable location.")
        errPrint("Expected: \(expectedPath)")
        errPrint("Actual: \(actualPath)")
        errPrint("Build and run from the source checkout:")
        errPrint("  \(Mpd.recommendedBuildCommand)")
        errPrint("  \(Mpd.pathExportHint)")
        errPrint("Do not copy the mpd binary elsewhere; always run the built binary from bin/.")
        exit(1)
    }
}

// MARK: - GlobalCommand (all --flag operations)

struct GlobalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mpd",
        abstract: "mpd — Moodle Plugin Development Environment",
        usage: """
            mpd <options>
            mpd list       [projects|runtimes|services|dbs]   (default: projects)
            mpd help       <projectname>
            mpd create     <projectname> [--type=<type>] [--git-repo=<url>] [--git-branch=<branch>] [--git-depth=<n>]
                                          (default type: moodle)
            mpd configure  <projectname> [KEY=VALUE ...]
                                          (e.g. MPD_DB=postgres:18, MPD_PHP_VERSION=8.4)
                                          (full set lives in /srv/projects/<projectname>/mpd.env)
            mpd start      <projectname>
            mpd stop       <projectname>
            mpd delete     <projectname> [--yes]
            mpd show       <projectname>
            """,
        subcommands: [ProjectSubcommand.self, ListSubcommand.self]
        )

    // Setup / start
    @Flag(name: .customLong("setup"),
          help: "Idempotent setup. Safe to run repeatedly. Adopts the current VM.")
    var setup: Bool = false
    @Flag(name: .customLong("start"),
          help: "Daily start: start services and verify tunnel + DNS. No provisioning.")
    var start: Bool = false
    @Flag(name: .customLong("stop"),
          help: "Graceful stop: mark running projects as stopped, then run environment-specific stop.")
    var stop: Bool = false
    @Flag(name: .customLong("restart"),
          help: "Restart: machine reboots the VM (graceful DB shutdown via systemd unit, mpd auto-starts on boot).")
    var restart: Bool = false

    // (Listing is now a verb: `mpd list [projects|runtimes|services|dbs]`. See ListSubcommand below.)

    // Runtime management
    @Option(name: .customLong("runtime-create"), help: ArgumentHelp("Provision a new runtime named <n>.", valueName: "name"))
    var runtimeCreate: String?
    @Option(name: .customLong("runtime-start"),  help: ArgumentHelp("Start a stopped runtime.", valueName: "name"))
    var runtimeStart: String?
    @Option(name: .customLong("runtime-stop"),   help: ArgumentHelp("Stop a running runtime.", valueName: "name"))
    var runtimeStop: String?
    @Option(name: .customLong("runtime-delete"), help: ArgumentHelp("Stop and remove a runtime (prompts unless --yes).", valueName: "name"))
    var runtimeDelete: String?
    @Option(name: .customLong("runtime"),        help: ArgumentHelp("Show runtime details and its projects.", valueName: "name"))
    var runtimeShow: String?

    // DB management
    @Option(name: .customLong("db-create"), help: ArgumentHelp("Create (or start) a DB container (e.g. postgres:17).", valueName: "name"))
    var dbCreate: String?
    @Option(name: .customLong("db-start"),  help: ArgumentHelp("Start a stopped DB container.", valueName: "name"))
    var dbStart: String?
    @Option(name: .customLong("db-stop"),   help: ArgumentHelp("Stop a running DB container.", valueName: "name"))
    var dbStop: String?
    @Option(name: .customLong("db-delete"), help: ArgumentHelp("Remove a DB container (prompts unless --yes).", valueName: "name"))
    var dbDelete: String?

    // Service management
    // (Service listing is `mpd list services` — see ListSubcommand below.)

    // Status
    @Flag(name: .customLong("status"), help: "Show context-aware status (text output).")
    var status: Bool = false

    // Hook diagnostics
    @Flag(name: .customLong("check-hooks"),
          help: "Cross-reference asset hook directories against the Event catalogue and print warnings for orphans and revision bumps. Also runs at the end of `mpd --setup`.")
    var checkHooks: Bool = false

    // Global modifiers
    @Flag(name: .customLong("yes"),  help: "Skip confirmation prompts (for scripted use).")
    var yes: Bool = false
    @Flag(name: .customLong("tui"), help: "Launch interactive terminal UI (same as bare mpd).")
    var tui: Bool = false
    @Flag(name: .customLong("debug"), help: "Print debug information.")
    var debug: Bool = false

    func run() throws {
        if debug { debugMode = true }
        if tui               { Mpd.TUI.run();               return }
        if status            { try handleStatus();          return }
        if setup             { try handleSetup();           return }
        if start             { try handleStart();            return }
        if stop              { try handleStop();             return }
        if restart           { try handleRestart();          return }

        if let n = runtimeCreate  { try handleRuntimeCreate(n);  return }
        if let n = runtimeStart   { try handleRuntimeStart(n);   return }
        if let n = runtimeStop    { try handleRuntimeStop(n);    return }
        if let n = runtimeDelete  { try handleRuntimeDelete(n);  return }
        if let n = runtimeShow    { try handleRuntimeShow(n);    return }
        if let n = dbCreate  { try handleDbCreate(n);       return }
        if let n = dbStart   { try handleDbStart(n);        return }
        if let n = dbStop    { try handleDbStop(n);         return }
        if let n = dbDelete  { try handleDbDelete(n);       return }

        if checkHooks { try handleCheckHooks(); return }

        // If we get here with no flags matched, show status as fallback
        try handleStatus()
    }
}

// MARK: - ListSubcommand

struct ListSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List entities — projects (default), runtimes, services, or DB containers.",
        usage: """
            mpd list                — list all projects (default)
            mpd list runtimes       — list runtime containers
            mpd list services       — list always-on infra services
            mpd list dbs            — list DB containers
            """
    )

    @Argument(help: ArgumentHelp(
        "What to list. Default: projects.",
        valueName: "what"))
    var what: String?

    func run() throws {
        switch (what ?? "projects").lowercased() {
        case "projects", "project":
            Mpd.showList()
        case "runtimes", "runtime":
            Mpd.Runtime.list()
        case "services", "service":
            Mpd.showServiceList()
        case "dbs", "db", "databases", "database":
            // Same prep the old --db-list flag did, since DB containers may
            // appear/disappear between mpd invocations.
            Mpd.Runtime.DB.rebuildStateCache(quiet: true)
            try? Mpd.Service.Dnsmasq.ensureReadyForServiceResolution()
            Mpd.showDbList()
        default:
            throw RuntimeError(
                "Unknown list target '\(what ?? "")'. " +
                "Use: projects, runtimes, services, or dbs.")
        }
    }
}

// MARK: - ProjectSubcommand

struct ProjectSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "Project operations.",
        shouldDisplay: false,
        subcommands: [
            ProjectShow.self,
            ProjectHelp.self,
            ProjectCreate.self,
            ProjectConfigure.self,
            ProjectStart.self,
            ProjectStop.self,
            ProjectDelete.self,
            ProjectRun.self,
        ])
}

struct ProjectShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", shouldDisplay: false)

    @Argument(help: "Project name")
    var project: String

    func run() throws {
        ProjectCommand.main(project, args: [])
    }
}

struct ProjectHelp: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "help", shouldDisplay: false)

    @Argument(help: "Project name")
    var project: String

    func run() throws {
        ProjectCommand.main(project, args: ["--help"])
    }
}

struct ProjectCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", shouldDisplay: false)

    @Argument(help: "Project name")
    var project: String

    @Argument(parsing: .captureForPassthrough)
    var args: [String] = []

    func run() throws {
        ProjectCommand.main(project, args: ["create"] + args)
    }
}

struct ProjectConfigure: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "configure", shouldDisplay: false)

    @Argument(help: "Project name")
    var project: String

    @Argument(parsing: .captureForPassthrough)
    var args: [String] = []

    func run() throws {
        ProjectCommand.main(project, args: ["configure"] + args)
    }
}

struct ProjectStart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", shouldDisplay: false)

    @Argument(help: "Project name")
    var project: String

    @Argument(parsing: .captureForPassthrough)
    var args: [String] = []

    func run() throws {
        ProjectCommand.main(project, args: ["start"] + args)
    }
}

struct ProjectStop: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", shouldDisplay: false)

    @Argument(help: "Project name")
    var project: String

    @Argument(parsing: .captureForPassthrough)
    var args: [String] = []

    func run() throws {
        ProjectCommand.main(project, args: ["stop"] + args)
    }
}

struct ProjectDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", shouldDisplay: false)

    @Argument(help: "Project name")
    var project: String

    @Argument(parsing: .captureForPassthrough)
    var args: [String] = []

    func run() throws {
        ProjectCommand.main(project, args: ["delete"] + args)
    }
}

struct ProjectRun: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", shouldDisplay: false)

    @Argument(help: "Project name")
    var project: String

    @Argument(parsing: .captureForPassthrough)
    var args: [String] = []

    func run() throws {
        ProjectCommand.main(project, args: args)
    }
}

// MARK: - ProjectCommand

struct ProjectCommand {
    static func main(_ project: String, args: [String]) {
        // Strip the `--` separator inserted at line 73: ArgumentParser's
        // captureForPassthrough hands it through verbatim instead of consuming
        // it as a separator, so per-verb arg loops would otherwise see it as
        // an unknown argument.
        let args = args.filter { $0 != "--" }
        do {
            // Check for bare project info or create (project may not be in projects.json yet)
            let verb = args.first ?? ""
            if verb.isEmpty {
                Mpd.Project.show(project: project)
                return
            }
            if verb == "create" {
                try Mpd.Project.create(project: project, args: Array(args.dropFirst()))
                return
            }
            if verb == "--help" {
                Mpd.Project.showHelp(project: project)
                return
            }

            // All other verbs — dispatch handles project lookup internally
            try Mpd.Project.dispatch(project: project, verb: verb, args: Array(args.dropFirst()))
        } catch {
            errPrint("Error: \(error.localizedDescription)")
            exit(1)
        }
    }
}

// MARK: - Entry point

// Shell completion short-circuit — bypasses non-root + exec-path checks
// because shells may invoke this during initialization in any context.
// Form: `mpd --complete <cword> <word0> <word1> ...`
//   <cword> is the index of the word being completed (0 == "mpd")
//   <wordN> are the literal words on the command line
// Output: candidates one per line on stdout. Exit 0 always.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--complete" {
    let cword = Int(CommandLine.arguments[2]) ?? 0
    let words = Array(CommandLine.arguments.dropFirst(3))
    Mpd.Completion.emit(cword: cword, words: words)
    exit(0)
}

enforceNonRootExecution()
enforceExpectedExecutableLocation()

let userArgs = Array(CommandLine.arguments.dropFirst())

// Bare `mpd` (no args) → launch TUI
if userArgs.isEmpty {
    Mpd.TUI.run()
} else {
    GlobalCommand.main(normalizeEntryArgs(userArgs))
}
