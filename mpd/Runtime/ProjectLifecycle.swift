// mpd — Mpd.Project lifecycle methods (split from Project.swift).
//
// Each method takes (or returns) a `RegisteredProjectRecord` from
// `Mpd.Runtime.State`. Lifecycle order:
//
//     create → configure → start → (running) → stop → delete
//
// `configure` is the strict validation step that produces the project's
// effective state — it sanitises mpd.env mutations, runs the project-type
// `configure.sh` (as the dev user via projectExec), and provisions the DB
// container based on the resulting `effective.json`. See ProjectOperations.swift.
//
// `show` / `showHelp` are read-only presentations (no side effects).
//
// All side-effect methods route container ops through `Mpd.Podman.*` and
// in-runtime exec through `projectExec` (which runs as the dev user — see
// ProjectHelpers.swift and ARCHITECTURE.md §7 "Privilege model").

import Foundation

/// Extract the hostname from a git URL. Handles `https://host/...`,
/// `git@host:owner/repo.git`, `ssh://user@host:port/path`. Returns nil
/// for shapes we don't recognise (local paths etc.) so the caller skips
/// the DNS pre-check.
private func gitHostFromURL(_ url: String) -> String? {
    if let comps = URLComponents(string: url), let host = comps.host, !host.isEmpty {
        return host
    }
    // scp-like SCP form: user@host:path
    if let at = url.firstIndex(of: "@"), let colon = url[url.index(after: at)...].firstIndex(of: ":") {
        let host = String(url[url.index(after: at)..<colon])
        if !host.isEmpty, !host.contains("/") { return host }
    }
    return nil
}

/// Resolve `host` from inside `container` by polling `getent hosts <host>`
/// (succeeds on any A/AAAA record) every 250ms up to ~5s. Non-fatal:
/// warns and returns on timeout, letting `git clone` produce its own
/// "Could not resolve host" message if DNS is genuinely unreachable.
/// The point is to absorb the brief settling window after dnsmasq
/// restart during runtime create — not to gate on internet availability.
private func waitForHostResolves(host: String, container: String, maxSeconds: Double = 5.0) {
    let probe = ["getent", "hosts", host]
    let interval: Double = 0.25
    let attempts = max(1, Int(maxSeconds / interval))
    for _ in 0..<attempts {
        if Mpd.Podman.execQuietly(container, probe) == 0 { return }
        Thread.sleep(forTimeInterval: interval)
    }
    print("Warning: '\(host)' did not resolve from inside the runtime within \(Int(maxSeconds))s. The next operation may fail with a DNS error.")
}

extension Mpd.Project {

    // MARK: - show

    static func show(project: String) {
        guard let entry = Mpd.Runtime.State.getProject(project) else {
            print("Project '\(project)' not found. Create it: mpd \(project) create")
            return
        }
        print("Project:        \(project)")
        print("Type:           \(entry.type.isEmpty ? "(not detected)" : entry.type)")
        let config = configurationDisplay(entry)
        if !config.isEmpty {
            print("Configuration:  \(config)")
        }
        print("Requested:      \(entry.requested.rawValue)")
        print("Current:        \(Mpd.Project.current(project).rawValue)")
        if entry.runtimeName.isEmpty {
            print("Runtime:        —\n\n  mpd \(project) create")
        } else {
            let rt = entry.runtimeName
            let rtRunning = Mpd.Podman.running(Mpd.Runtime.containerName(rt))
            if entry.requested == .running && rtRunning {
                print("Runtime:        \(rt)")
                if !entry.urls.isEmpty {
                    let labelWidth = entry.urls.map { $0.label.count }.max() ?? 0
                    for (i, u) in entry.urls.enumerated() {
                        let prefix = i == 0 ? "URLs:           " : "                "
                        let pad = String(repeating: " ", count: max(0, labelWidth - u.label.count))
                        print("\(prefix)\(u.label)\(pad)  \(u.url)")
                    }
                }
                print("SSH:            ssh \(rt).runtime.mpd.test")
                print("Directory:      /srv/projects/\(project)")
                // Project-type-specific resolved settings (from mpd.env). Generic
                // dump — Swift doesn't interpret these, just surfaces them so the
                // user can see what configure.sh actually picked.
                if let eff = readProjectEffectiveDisplay(project: project), !eff.isEmpty {
                    let keyWidth = eff.keys.map(\.count).max() ?? 0
                    let sortedKeys = eff.keys.sorted()
                    for (i, k) in sortedKeys.enumerated() {
                        let prefix = i == 0 ? "Settings:       " : "                "
                        let pad = String(repeating: " ", count: max(0, keyWidth - k.count))
                        print("\(prefix)\(k)\(pad)  \(eff[k]!)")
                    }
                }
            } else {
                print("Runtime:        \(rt)  (last used — \(rtRunning ? "running" : "stopped"))")
                print("Directory:      /srv/projects/\(project)")
                print("\n  mpd \(project) start")
            }
        }
    }

    // MARK: - create

    static func create(project: String, args: [String]) throws {
        guard Mpd.Project.isValidName(project) else {
            throw RuntimeError(
                "'\(project)' is not a valid project name. " +
                "Use lowercase letters and digits, starting with a letter, " +
                "minimum 2 characters. Internal dashes allowed " +
                "(e.g. 'moodle520-cftunnel').")
        }

        if project == "project" || projectVerbs.contains(project) {
            throw RuntimeError(
                "Project name '\(project)' is reserved by CLI syntax. Choose another name.")
        }

        guard Mpd.Runtime.State.getProject(project) == nil else {
            throw RuntimeError("Project '\(project)' already exists.")
        }

        // Create-only flags. No --db, no project-type knobs — those go through
        // `mpd configure <project> KEY=VALUE` which writes to the project's
        // mpd.env (seeded from the type's mpd-template.env by project-create.sh).
        var gitRepo = ""
        var gitBranch = ""
        var gitDepth = ""
        var typeHint = ""

        for arg in args {
            if arg.hasPrefix("--git-repo=") { gitRepo = String(arg.dropFirst(11)) }
            else if arg.hasPrefix("--git-branch=") { gitBranch = String(arg.dropFirst(13)) }
            else if arg.hasPrefix("--git-depth=") { gitDepth = String(arg.dropFirst(12)) }
            else if arg.hasPrefix("--type=") { typeHint = String(arg.dropFirst(7)) }
            else {
                throw RuntimeError(
                    "Unknown argument '\(arg)' for create. " +
                    "Configure knobs live in mpd.env: `mpd \(project) configure KEY=VALUE`.")
            }
        }

        // Type resolution: explicit `--type=` always wins. Otherwise
        // try name-based autodetection — exact match (project name
        // equals a known type) or suffix match (project name ends
        // with `-<type>` for opt-in types). Falls back to `moodle`
        // as mpd's overall default.
        if typeHint.isEmpty {
            typeHint = ProjectType.detectFromName(project) ?? "moodle"
        }

        // Resolve and ensure runtime first, so failures happen before any project directory/state changes.
        let createRuntime = resolveRuntimeForClone(typeHint: typeHint)
        try ensureRuntime(name: createRuntime)
        let createContainer = Mpd.Runtime.containerName(createRuntime)
        guard Mpd.Podman.running(createContainer) else {
            throw RuntimeError("Runtime '\(createRuntime)' failed to start.")
        }

        // Ensure project directory exists inside the resolved runtime container.
        // Pre-existing dir + mpd.env are sacred (project-create.sh below leaves
        // an existing mpd.env alone).
        step("Ensuring /srv/projects/\(project)/")
        guard projectExec(createContainer, ["mkdir", "-p", "/srv/projects/\(project)"]) == 0 else {
            throw RuntimeError("Failed to create /srv/projects/\(project) in runtime '\(createRuntime)'.")
        }

        // Clone repo if requested.
        if !gitRepo.isEmpty {
            // Pre-clone DNS check: when the runtime was just created in the
            // same `mpd create` call, dnsmasq was restarted moments ago and
            // the runtime's resolver path can race against the clone. Verify
            // the git host resolves from inside the runtime, retrying briefly,
            // before issuing the clone — surfaces a clear error and avoids
            // the user having to retry.
            if let host = gitHostFromURL(gitRepo) {
                waitForHostResolves(host: host, container: createContainer)
            }

            step("Cloning \(gitRepo)")
            // --progress forces git to print progress even when it can't
            // detect a TTY on stderr. podman exec -it allocates a pseudo-TTY
            // but git's isatty check sometimes still returns false here, so
            // the clone runs silently for big repos. --progress is the
            // unambiguous fix.
            var cloneArgs = ["git", "clone", "--progress", gitRepo, "/srv/projects/\(project)"]
            if !gitBranch.isEmpty {
                cloneArgs.insert(contentsOf: ["-b", gitBranch], at: cloneArgs.count - 1)
            }
            if !gitDepth.isEmpty {
                cloneArgs.insert("--depth=\(gitDepth)", at: cloneArgs.count - 1)
            }
            guard projectExecInteractive(createContainer, cloneArgs) == 0 else {
                throw RuntimeError("git clone failed.")
            }
        }

        // Run project-type's project-create.sh (seeds mpd.env from template if
        // absent, adds /mpd.env to .git/info/exclude). Optional — types without
        // it skip silently.
        let pType = ProjectType(typeHint)
        if let config = try? pType.loadConfiguration() {
            let scriptPath = "\(try Mpd.VM.assetsPath())/runtimes/\(config.assetsRuntime)/project_types/\(config.assetsType)/project-create.sh"
            if FileManager.default.fileExists(atPath: scriptPath) {
                step("Scaffolding project from \(typeHint) template")
                let cmdArgs = ["bash", "/opt/mpd/assets/runtimes/\(config.assetsRuntime)/project_types/\(config.assetsType)/project-create.sh", project]
                guard projectExec(createContainer, cmdArgs) == 0 else {
                    throw RuntimeError("project-create.sh failed for project '\(project)'.")
                }
            }
        }

        // Register the project only after scaffolding has succeeded. If
        // anything above threw, the entry is never written; /srv/projects/<n>/
        // is left in place for the user to inspect, fix, or delete.
        let entry = RegisteredProjectRecord(name: project, type: typeHint)
        Mpd.Runtime.State.upsertProject(entry)

        print("")
        ok("Project '\(project)' scaffolded.")
        print("  Edit /srv/projects/\(project)/mpd.env if needed, then:")
        print("    mpd \(project) configure")
    }

    // MARK: - start

    static func start(project: String, entry: inout RegisteredProjectRecord, args: [String]) throws {
        let runtimeName = entry.runtimeName
        guard !runtimeName.isEmpty else {
            throw RuntimeError(
                "No runtime assigned to '\(project)'.\n" +
                "Use: mpd \(project) create")
        }

        // Ensure runtime exists and is running
        try ensureRuntime(name: runtimeName)
        let cName = Mpd.Runtime.containerName(runtimeName)
        if !Mpd.Podman.running(cName) {
            try Mpd.Runtime.start(runtimeName)
        }

        // Ensure DB is running (types with DB)
        if !entry.databaseEngine.isEmpty {
            try Mpd.Runtime.DB.ensure(engine: entry.databaseEngine, version: entry.databaseVersion)
        }

        // Pre-start hooks fire here — runtime + DB are up but project setup
        // hasn't run yet. Hook authors can apply per-project DB migrations,
        // seed data, etc. Failures abort the start (`.abort` failure mode).
        try Mpd.Hooks.fire(EventProjectPreStart(
            project: project,
            runtime: runtimeName,
            dbEngine: entry.databaseEngine,
            dbVersion: entry.databaseVersion
        ), verb: "start")

        // Ensure per-project TLS cert exists
        try ensureProjectCert(project: project, urls: entry.urls)

        // Write dnsmasq record pointing project DNS to this runtime's IP
        let runtimeIP = Mpd.Podman.label(cName, "mpd.ip")
        if !runtimeIP.isEmpty {
            writeDnsmasqRecord(project: project, urls: entry.urls, runtimeIP: runtimeIP)
        }

        // Run project-setup in the runtime (script path from configuration.json)
        let pType = ProjectType(entry.type)
        if let config = try? pType.loadConfiguration() {
            step("Setting up '\(project)' in '\(runtimeName)'")
            let setupArgs = [
                "bash", "/opt/mpd/assets/runtimes/\(config.assetsRuntime)/project_types/\(config.assetsType)/project-setup.sh", project,
            ]
            guard projectExec(cName, setupArgs) == 0
            else { throw RuntimeError("project-setup.sh failed.") }
        }

        entry.requested = .running
        Mpd.Runtime.State.upsertProject(entry)

        // Post-start hooks fire here — project is fully live. Failures
        // log a warning but don't undo the start (`.continue` failure mode).
        try Mpd.Hooks.fire(EventProjectPostStart(
            project: project,
            runtime: runtimeName,
            dbEngine: entry.databaseEngine,
            dbVersion: entry.databaseVersion
        ), verb: "start")

        let url = projectURL(entry: entry)
        ok("'\(project)' is running.")
        if !url.isEmpty { print("  \(url)") }
    }

    // MARK: - stop

    static func stop(project: String, entry: inout RegisteredProjectRecord, args: [String]) throws {
        guard entry.requested == .running else {
            print("'\(project)' is already stopped.")
            return
        }
        let runtimeName = entry.runtimeName
        let cName = Mpd.Runtime.containerName(runtimeName)

        // Pre-stop hooks fire here — project is still running, runtime
        // still up. Hook authors can drain in-flight work, flush caches,
        // etc. `.continue` failure mode — we never block a stop.
        try Mpd.Hooks.fire(EventProjectPreStop(
            project: project,
            runtime: runtimeName,
            dbEngine: entry.databaseEngine,
            dbVersion: entry.databaseVersion
        ), verb: "stop")

        // Stop dev server if the type requires it (configuration.json: stop.systemdStop)
        let pType = ProjectType(entry.type)
        if let config = try? pType.loadConfiguration(), config.stopSystemd {
            if Mpd.Podman.running(cName) {
                projectExec(cName, ["sudo", "systemctl", "stop", "mpd-\(project)"])
            }
        }

        entry.requested = .stopped
        Mpd.Runtime.State.upsertProject(entry)

        // Remove dnsmasq record for this project
        removeDnsmasqRecord(project: project)

        // Demand-driven DB model (see docs/HOOKS.md §"Resource lifecycle
        // model"): databases are not auto-stopped when their last project
        // stops. Devs poke at DBs after the project is down; beginners
        // keep one DB. Memory reclamation is `mpd --gc`'s job, not the
        // project-stop path's. Same rationale for runtimes — explicit user
        // intent, not cascade.

        ok("'\(project)' stopped.")
    }

    // MARK: - delete

    static func delete(project: String, entry: RegisteredProjectRecord, args: [String]) throws {
        let skipPrompt = args.contains("--yes")
        let rt = entry.runtimeName
        let cName = rt.isEmpty ? "" : Mpd.Runtime.containerName(rt)

        print("Project:  \(project)")
        print("Type:     \(entry.type.isEmpty ? "(not detected)" : entry.type)")
        print("Runtime:  \(rt.isEmpty ? "(none)" : rt)")
        print("Source:   /srv/projects/\(project)/")
        print("This will remove the DB, dataroot, source tree, and all config files.")

        guard skipPrompt || promptYesNo("Remove project '\(project)'?") else {
            print("Aborted.")
            return
        }

        // Stop first
        if entry.requested == .running {
            var mutable = entry
            try? stop(project: project, entry: &mutable, args: [])
        }

        // Run project-delete.sh in runtime (removes Apache alias, systemd unit, etc.)
        if !cName.isEmpty && Mpd.Podman.running(cName) {
            let pType = ProjectType(entry.type)
            if let config = try? pType.loadConfiguration() {
                projectExec(cName, [
                    "bash",
                    "/opt/mpd/assets/runtimes/\(config.assetsRuntime)/project_types/\(config.assetsType)/project-delete.sh", project,
                ])
            }
        }

        // Drop DB
        if !entry.databaseEngine.isEmpty {
            let dbCName = Mpd.Runtime.DB.containerName(engine: entry.databaseEngine, version: entry.databaseVersion)
            if Mpd.Podman.running(dbCName) {
                try? Mpd.Runtime.DB.drop(engine: entry.databaseEngine, container: dbCName, named: project)
            }
        }

        // Remove dnsmasq record
        removeDnsmasqRecord(project: project)

        // Remove source and meta from volume
        _ = Mpd.Podman.volumeToolRun(command: [
            "rm", "-rf",
            "/srv/projects/\(project)",
            "/srv/data/\(project)",
            "/srv/meta/\(project)",
        ])

        Mpd.Runtime.State.deleteProject(project)

        // Reconcile sidecars — drops e.g. selenium if this was the last project
        // with `kind: behat` on the runtime.
        if !rt.isEmpty {
            try? Mpd.Runtime.reconcileSidecars(forRuntime: rt)
        }

        ok("Project '\(project)' deleted.")
    }

    // MARK: - showHelp

    static func showHelp(project: String) {
        print("Usage: mpd <verb> \(project) [options...]")
        print("\nVerbs:")
        print("  show       \(project)                       project details (also: bare `mpd show \(project)`)")
        print("  create     \(project) [--type=<type>] [--git-repo=<url>] [--git-branch=<branch>] [--git-depth=<n>]")
        print("                                              (default type: moodle)")
        print("  configure  \(project) [KEY=VALUE ...]       (e.g. MPD_DB=postgres:18, MPD_PHP_VERSION=8.4;")
        print("                                              full set lives in /srv/projects/\(project)/mpd.env)")
        print("  start      \(project)")
        print("  stop       \(project)")
        print("  delete     \(project) [--yes]")
        print("")
        print("Project-type-specific operations (mdl-cron, phpunit, composer, …) are tools,")
        print("not host-side verbs. SSH into the runtime and run them on PATH:")
        print("  ssh user@<runtime>.runtime.mpd.test")
    }
}
