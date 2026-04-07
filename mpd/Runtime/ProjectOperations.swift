// mpd — Mpd.Project.configure
//
// **`configure(...)`** — the strict project step. Flow:
//   1. Parse positional KEY=VALUE args, validate `^MPD_[A-Z0-9_]+=.*$`.
//   2. Sanitise: reserved keys (e.g. MPD_DB) get strict validators;
//      others get a generic safe-charset check.
//   3. Apply mutations to `/srv/projects/<n>/mpd.env` via the
//      `set-mpd-env.sh` helper (empty value → delete the line).
//   4. Run the project-type `scripts/configure.sh` as the dev user
//      (projectExec — see ProjectHelpers.swift). That script sources
//      the layered env, generates project config files, and writes
//      `/srv/meta/<n>/{effective,urls}.json`.
//   5. Read `effective.json` `dbTag`, re-sanitise, provision the DB
//      container (Mpd.Runtime.DB.ensure) if non-empty.
//   6. Persist updated record + URL list.
//
// Project-type-specific functionality (mdl-cron, phpunit, …) is exposed
// as tools inside the runtime container, not as host-side verbs — see
// ARCHITECTURE.md §7.

import Foundation

extension Mpd.Project {

    // MARK: - configure

    static func configure(project: String, entry: inout RegisteredProjectRecord, args: [String]) throws {
        // CLI surface: positional KEY=VALUE pairs, each matching ^MPD_[A-Z0-9_]+=.*$.
        // Swift sanitises and writes mutations to /srv/projects/<n>/mpd.env, then
        // the project-type configure.sh resolves the layered env (mpd-user.env +
        // project mpd.env) and emits dbTag/dbEngine/etc. into effective.json.
        // Swift reads effective.json to provision the DB container.
        var mutations: [(key: String, value: String)] = []
        for arg in args {
            if arg.hasPrefix("--type=") {
                throw RuntimeError("'--type' is not supported in configure. Choose project type at create time.")
            }
            if arg.hasPrefix("--") {
                throw RuntimeError(
                    "Unknown flag '\(arg)'. Configure takes KEY=VALUE pairs " +
                    "(e.g. MPD_DB=postgres:18, MPD_PHP_VERSION=8.4).")
            }
            guard let eqIdx = arg.firstIndex(of: "=") else {
                throw RuntimeError(
                    "Argument '\(arg)' is not KEY=VALUE. " +
                    "Configure takes positional pairs like MPD_DB=postgres:18.")
            }
            let key = String(arg[..<eqIdx])
            let value = String(arg[arg.index(after: eqIdx)...])
            try sanitiseEnvKey(key)
            try sanitiseEnvValue(key: key, value: value)
            mutations.append((key, value))
        }

        // Step 1: Project type is immutable and must already be set.
        if entry.type.isEmpty {
            throw RuntimeError(
                "Project type is not set for '\(project)'.\n" +
                "Create a new project to choose a type (default: moodle).")
        }

        let pType = ProjectType(entry.type)

        // Step 2: Resolve runtime.
        if entry.runtimeName.isEmpty {
            let runtimeName = pType.defaultRuntimeName
            if runtimeName.isEmpty {
                throw RuntimeError(
                    "Cannot determine runtime for '\(project)' because project type is missing.\n" +
                    "Create a new project to choose a type (default: moodle).")
            }
            entry.runtimeName = runtimeName
        }

        let projectTypeConfig = try? pType.loadConfiguration()

        // Step 3: Apply mutations to /srv/projects/<n>/mpd.env.
        let cName = Mpd.Runtime.containerName(entry.runtimeName)
        let runtimeWasRunning = Mpd.Podman.running(cName)
        try ensureRuntime(name: entry.runtimeName)

        if !mutations.isEmpty {
            step("Updating /srv/projects/\(project)/mpd.env")
            for (key, value) in mutations {
                let setCmd = [
                    "bash", "/mnt/assets/runtime-base/tools/set-mpd-env",
                    "/srv/projects/\(project)/mpd.env", key, value,
                ]
                guard projectExec(cName, setCmd) == 0 else {
                    throw RuntimeError("Failed to update mpd.env (key '\(key)').")
                }
            }
        }

        // Step 4: Run project-type configure.sh — resolves layered mpd.env,
        // generates config files, emits effective.json + urls.json.
        // Write project.json *before* configure.sh runs so source-mpd-env.sh
        // can read runtime/type and source the matching mpd-defaults.env files.
        // The full project.json (with URLs and DB engine) is rewritten at the
        // end of this function once configure.sh has populated those fields.
        writeProjectMeta(project: project, entry: entry)
        if let config = projectTypeConfig {
            let scriptPath = "\(try Mpd.Core.Assets.path())/runtimes/\(config.assetsRuntime)/project_types/\(config.assetsType)/scripts/configure.sh"
            if FileManager.default.fileExists(atPath: scriptPath) {
                let cmdArgs = ["bash", "/mnt/assets/runtimes/\(config.assetsRuntime)/project_types/\(config.assetsType)/scripts/configure.sh", project]
                guard projectExec(cName, cmdArgs) == 0 else {
                    throw RuntimeError("configure.sh failed for project '\(project)'.")
                }
            }
        }

        // Step 5: Read effective.json — pick up dbTag (from layered mpd.env)
        // and the URL list configure.sh wrote.
        let effective = readProjectEffectiveDisplay(project: project)
        let dbTag = effective?["dbTag"] as? String ?? ""

        if !dbTag.isEmpty {
            let parsed = try Mpd.Runtime.DB.parseTag(dbTag)
            let containerName = Mpd.Runtime.DB.containerName(engine: parsed.engine, version: parsed.version)
            step("Ensuring DB container \(containerName)")
            try Mpd.Runtime.DB.ensure(engine: parsed.engine, version: parsed.version)
            step("Creating database '\(project)'")
            try Mpd.Runtime.DB.create(
                engine: parsed.engine,
                container: containerName,
                named: project)
            entry.databaseEngine = parsed.engine
            entry.databaseVersion = parsed.version
            entry.databaseId = Mpd.Runtime.DB.shortName(engine: parsed.engine, version: parsed.version)

            // Refresh dnsmasq's databases.conf so `<db>.db.mpd.test` resolves
            // from inside runtime containers.
            Mpd.Environment.PodmanMachine.rebuildDatabaseStateCache(quiet: true)
            try? Mpd.Service.Dnsmasq.ensureReadyForServiceResolution()
        } else {
            // No DB this project — clear any previous DB state on the entry.
            entry.databaseEngine = ""
            entry.databaseVersion = ""
            entry.databaseId = ""
        }

        // Step 6: URL list, meta, status.
        entry.urls = readProjectURLs(project: project)
        if entry.status == .notConfigured && !entry.type.isEmpty {
            entry.status = .stopped
        }
        writeProjectMeta(project: project, entry: entry)
        Mpd.Runtime.State.upsertProject(entry)

        // Step 7: Sidecars + cert.
        try? Mpd.Runtime.reconcileSidecars(forRuntime: entry.runtimeName)
        try ensureProjectCert(project: project, urls: entry.urls)

        // Keep configure low-impact: if it needed to start a runtime for
        // repair work, stop it again unless some project is running on it.
        if !runtimeWasRunning {
            let hasRunningProjects = Mpd.Runtime.State.loadProjects().projects.contains {
                $0.runtimeName == entry.runtimeName && $0.status == .running
            }
            if !hasRunningProjects {
                try? Mpd.Runtime.stop(entry.runtimeName)
            }
        }

        ok("Project '\(project)' configured. Type: \(entry.type), Status: \(entry.status)")
    }

    // MARK: - mpd.env mutation sanitisation

    /// Validates KEY against `^MPD_[A-Z0-9_]+$`.
    private static func sanitiseEnvKey(_ key: String) throws {
        guard !key.isEmpty else {
            throw RuntimeError("Empty key in KEY=VALUE argument.")
        }
        guard key.hasPrefix("MPD_") else {
            throw RuntimeError("Key '\(key)' must start with 'MPD_'.")
        }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        guard key.allSatisfy({ allowed.contains($0) }) else {
            throw RuntimeError("Key '\(key)' must match ^MPD_[A-Z0-9_]+$.")
        }
    }

    /// Sanitises VALUE per key. Reserved keys (e.g. MPD_DB) get strict
    /// type-specific validators; other keys get a generic safe-charset check.
    /// Empty value is always allowed (means "delete the line").
    private static func sanitiseEnvValue(key: String, value: String) throws {
        if value.isEmpty { return }
        switch key {
        case "MPD_DB":
            // Validates engine whitelist + version regex; throws on bad input.
            _ = try Mpd.Runtime.DB.parseTag(value)
        default:
            // Generic safe-charset for free-form mpd.env values.
            // Allows alphanumerics, dot, dash, underscore, colon, slash, comma,
            // at-sign, equals, plus. Blocks shell metas (whitespace, quotes,
            // $, `, ;, &, |, <, >, parens, braces, brackets, newline, etc.).
            let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-:/,@=+")
            guard value.allSatisfy({ allowed.contains($0) }) else {
                throw RuntimeError(
                    "Value for '\(key)' contains disallowed characters. " +
                    "Only [A-Za-z0-9._:/,@=+-] are accepted via the CLI; " +
                    "edit /srv/projects/<project>/mpd.env directly for free-form values.")
            }
        }
    }

}
