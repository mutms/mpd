// mpd — shell completion candidate emitter.
//
// Single source of truth for both bash and zsh. The shell-side shims under
// `assets/completions/` invoke `mpd --complete <cword> <word0> <word1> ...`
// and feed the lines we print here back to compadd / COMPREPLY.
//
// Why dynamic instead of a static script: mpd's grammar depends on filesystem
// state (project list, runtime list, db list) and on JSON-driven verb sets
// (per-runtime + per-project-type). Hand-writing the same grammar twice and
// keeping it in sync would drift; Swift already knows everything.
//
// Latency budget: each Tab press forks `mpd`. Keep this path lightweight —
// no podman calls, no network, just state-file reads and asset listing.

import Foundation

extension Mpd.Completion {

    /// Entry point invoked by main.swift's --complete short-circuit.
    /// Prints one candidate per line on stdout. Always exits 0 (errors are
    /// silently mapped to "no candidates" — the shell shouldn't see them).
    static func emit(cword: Int, words: [String]) {
        let prefix = words.indices.contains(cword) ? words[cword] : ""
        let candidates = candidates(cword: cword, words: words, prefix: prefix)
        for c in candidates where c.hasPrefix(prefix) {
            print(c)
        }
    }

    // MARK: - Dispatch

    private static func candidates(cword: Int, words: [String], prefix: String) -> [String] {
        // word[0] == "mpd"
        if cword <= 1 {
            return firstTokenCandidates(prefix: prefix)
        }
        guard words.indices.contains(1) else { return [] }
        let first = words[1]

        // Global option that takes a value: complete the value.
        if cword == 2, first.hasPrefix("--") {
            return globalOptionValueCandidates(forOption: first)
        }

        // `mpd list <TAB>` → suggest entity types.
        if cword == 2, first == "list" {
            return ["projects", "runtimes", "services", "dbs"]
        }

        // Verb-first form: word[1] is a verb → second token is project name.
        if cword == 2, projectVerbs.contains(first) {
            // For `mpd create <new-project>`, no name suggestion list applies
            // (any unused name is fine); for the other verbs, only existing
            // projects make sense.
            return first == "create" ? [] : projectNames()
        }
        if cword >= 3 {
            return verbArgCandidates(verb: first)
        }
        return []
    }

    // MARK: - First token: verbs + global flags

    private static func firstTokenCandidates(prefix: String) -> [String] {
        if prefix.hasPrefix("-") {
            return globalFlags
        }
        // Verbs first (project verbs + the standalone `list`), then global flags.
        return Array(projectVerbs).sorted() + ["list"] + globalFlags
    }

    /// Static list of every long flag/option mpd supports. Mirrors @Flag/@Option
    /// in main.swift. Add new entries here when you add new top-level flags.
    private static let globalFlags: [String] = [
        "--setup",
        "--start",
        "--stop",
        "--uninstall",
        "--setup-info",
        "--runtime-create",
        "--runtime-start",
        "--runtime-stop",
        "--runtime-delete",
        "--runtime",
        "--db-create",
        "--db-start",
        "--db-stop",
        "--db-delete",
        "--status",
        "--yes",
        "--tui",
        "--debug",
        "--help",
    ]

    // MARK: - Value of a global option (cword == 2 and first starts with --)

    private static func globalOptionValueCandidates(forOption flag: String) -> [String] {
        switch flag {
        case "--runtime-start", "--runtime-stop", "--runtime-delete", "--runtime":
            return runtimeNames()
        case "--db-start", "--db-stop", "--db-delete":
            return databaseNames()
        case "--db-create":
            // Common engine:version combos. The DB layer accepts engine alone
            // (defaulted version) plus engine:version.
            return ["postgres", "postgres:17", "mariadb", "mariadb:10.11", "mysql", "mysql:8.4"]
        case "--runtime-create":
            // Suggest runtimes that have an asset definition but aren't created yet.
            return uncreatedRuntimeAssetNames()
        default:
            return []
        }
    }

    // MARK: - Verb argument completion (cword >= 3)
    //
    // Public form: `mpd <verb> <project> [args...]`. word[1] = verb,
    // word[2] = project, word[3..] = verb-specific flags/values.

    private static func verbArgCandidates(verb: String) -> [String] {
        switch verb {
        case "create":
            // No --db: project-type knobs live in mpd.env and are set via configure.
            return ["--type=", "--git-repo=", "--git-branch=", "--git-depth=", "--yes"]
        case "configure":
            // Suggest commonly-set keys; the user can pass any MPD_* key.
            return ["MPD_DB=", "MPD_PHP_VERSION=", "MPD_PHP_MOODLE_BEHAT=", "--yes"]
        case "delete":
            return ["--yes"]
        default:
            return []
        }
    }

    // MARK: - State sources

    /// Names of registered projects from `~/.mpd/machines/<n>/projects.json`.
    private static func projectNames() -> [String] {
        Mpd.Runtime.State.loadProjects().projects.map(\.name)
    }

    /// Names of created runtimes (directories under
    /// `~/.mpd/machines/<n>/runtimes/`).
    private static func runtimeNames() -> [String] {
        let dir = Mpd.Runtime.State.runtimesDir
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return []
        }
        return entries.sorted()
    }

    /// Names of DB containers from `~/.mpd/machines/<n>/databases.json`.
    private static func databaseNames() -> [String] {
        Mpd.Runtime.State.loadDatabases().databases.map(\.databaseId)
    }

    /// Names of runtimes that have asset definitions but no state entry yet —
    /// candidates for `--runtime-create`.
    private static func uncreatedRuntimeAssetNames() -> [String] {
        guard let assets = try? Mpd.Core.Assets.path() else { return [] }
        let runtimesAssetDir = "\(assets)/runtimes"
        guard let assetEntries = try? FileManager.default.contentsOfDirectory(atPath: runtimesAssetDir)
        else { return [] }
        let created = Set(runtimeNames())
        return assetEntries.filter { !created.contains($0) }.sorted()
    }
}
