// mpd — Mpd.Project namespace, dispatch entry point.
//
// `dispatch(project:verb:args:)` is the single entry point called from
// `main.swift`'s ProjectCommand. The verb set is fixed and Swift-only:
//
//   show / help — print info; no runtime needed
//   create      — scaffold a new project
//   configure   — apply mpd.env and re-provision DB
//   start       — bring project up
//   stop        — bring project down
//   delete      — remove project
//
// Project-type-specific functionality (mdl-cron, phpunit, …) lives as
// **tools** inside the runtime container, on PATH (see ARCHITECTURE.md §7).
// The host CLI surface stays small and uniform across all project types.
//
// Implementation lives in:
// - ProjectLifecycle.swift  — create / start / stop / delete / show / help
// - ProjectOperations.swift — configure
// - ProjectHelpers.swift    — projectExec (--user dev), URL helpers, etc.

import Foundation

extension Mpd.Project {

    // MARK: - Name validation

    /// Project identifier rule. Like a runtime name (lowercase letter
    /// + alphanumerics, min length 2) but allows internal dashes
    /// (no leading/trailing/consecutive) — needed for the
    /// `<target>-cftunnel` naming convention and other suffix-style
    /// project type names. Project names don't appear in mpd-internal
    /// name parsing the way runtime names do.
    static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: #/[a-z][a-z0-9]*(-[a-z0-9]+)*/#) != nil
            && name.count >= 2
    }

    // MARK: - Entry point: dispatch from ProjectCommand

    static func dispatch(project: String, verb: String, args: [String]) throws {
        switch verb {
        case "", "show":
            show(project: project)
            return
        case "help", "--help":
            showHelp(project: project)
            return
        case "create":
            try create(project: project, args: args)
            return
        default:
            break
        }

        // configure / start / stop / delete need the project to exist
        guard var entry = Mpd.Runtime.State.getProject(project) else {
            throw RuntimeError(
                "Project '\(project)' not found.\n" +
                "Create it first: mpd create \(project)")
        }

        switch verb {
        case "configure":
            try configure(project: project, entry: &entry, args: args)
        case "start":
            try start(project: project, entry: &entry, args: args)
        case "stop":
            try stop(project: project, entry: &entry, args: args)
        case "delete":
            try delete(project: project, entry: entry, args: args)
        default:
            throw RuntimeError(
                "Unknown verb '\(verb)'. Valid verbs: create, configure, start, stop, delete, show.\n" +
                "Project-type-specific operations are tools — SSH into the runtime " +
                "(`ssh user@<runtime>.runtime.\(Mpd.Net.zone)`) and run them on PATH.")
        }
    }
}
