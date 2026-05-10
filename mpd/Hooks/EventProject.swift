// mpd — Project-level hook events
//
// Events fired around the project verbs (start / stop / etc.). Each
// event carries the project's runtime + DB context as typed fields,
// surfaced to hook scripts as `MPD_HOOK_*` env vars. Audiences resolve
// to the project's specific runtime / DB container — not all running
// containers — via the per-event `containers(for:)` override.
//
// See docs/HOOKS.md for the v1 catalogue and design.

import Foundation

/// Fires after the runtime + DB containers are ensured up but before
/// project-setup.sh runs. Hook authors can use this to apply per-project
/// schema migrations, seed data, ensure indexes, etc., on a DB that's
/// guaranteed to be reachable.
///
/// Audience: the project's DB container only (not all DBs).
/// Failure: `.abort` — pre-start failures should stop the verb so the
/// user sees the problem immediately.
struct EventProjectPreStart: Mpd.Hooks.Event {
    let project: String
    let runtime: String
    let dbEngine: String
    let dbVersion: String

    static let audiences: [Mpd.Hooks.Audience] = [.database]
    static let onFailure: Mpd.Hooks.FailureMode = .abort

    var env: [String: String] {
        [
            "PROJECT": project,
            "RUNTIME": runtime,
            "DB_ENGINE": dbEngine,
            "DB_VERSION": dbVersion,
        ]
    }

    func containers(for audience: Mpd.Hooks.Audience) -> [String] {
        switch audience {
        case .database:
            guard !dbEngine.isEmpty else { return [] }
            let cName = Mpd.Runtime.DB.containerName(engine: dbEngine, version: dbVersion)
            return Mpd.Podman.running(cName) ? [cName] : []
        case .runtime:
            guard !runtime.isEmpty else { return [] }
            let cName = Mpd.Runtime.containerName(runtime)
            return Mpd.Podman.running(cName) ? [cName] : []
        case .service:
            return Mpd.Hooks.runningContainers(for: audience)
        }
    }
}

/// Fires per-project-stop, immediately after entering the stop verb
/// (project still marked running). Hook authors can use this for
/// graceful per-project shutdown logic — drain in-flight work, flush
/// caches, etc. Today's `sudo systemctl stop mpd-<project>` for project
/// types with `stopSystemd: true` runs separately in Swift; in a future
/// pass that one-liner can move into a project-type hook.
///
/// Audience: the project's runtime container only.
/// Failure: `.continue` — stops must always complete.
struct EventProjectPreStop: Mpd.Hooks.Event {
    let project: String
    let runtime: String
    let dbEngine: String
    let dbVersion: String

    static let audiences: [Mpd.Hooks.Audience] = [.runtime]
    static let onFailure: Mpd.Hooks.FailureMode = .continue

    var env: [String: String] {
        [
            "PROJECT": project,
            "RUNTIME": runtime,
            "DB_ENGINE": dbEngine,
            "DB_VERSION": dbVersion,
        ]
    }

    func containers(for audience: Mpd.Hooks.Audience) -> [String] {
        switch audience {
        case .runtime:
            guard !runtime.isEmpty else { return [] }
            let cName = Mpd.Runtime.containerName(runtime)
            return Mpd.Podman.running(cName) ? [cName] : []
        case .database:
            guard !dbEngine.isEmpty else { return [] }
            let cName = Mpd.Runtime.DB.containerName(engine: dbEngine, version: dbVersion)
            return Mpd.Podman.running(cName) ? [cName] : []
        case .service:
            return Mpd.Hooks.runningContainers(for: audience)
        }
    }
}

/// Fires per-project-start, after the project is fully live and its
/// status is recorded as running. Useful for post-start announcements
/// (cache warming, log preparation, "first request" triggers).
///
/// Audience: the project's runtime container only.
/// Failure: `.continue` — the project is already started; a hook
/// failure shouldn't undo that.
struct EventProjectPostStart: Mpd.Hooks.Event {
    let project: String
    let runtime: String
    let dbEngine: String
    let dbVersion: String

    static let audiences: [Mpd.Hooks.Audience] = [.runtime]
    static let onFailure: Mpd.Hooks.FailureMode = .continue

    var env: [String: String] {
        [
            "PROJECT": project,
            "RUNTIME": runtime,
            "DB_ENGINE": dbEngine,
            "DB_VERSION": dbVersion,
        ]
    }

    func containers(for audience: Mpd.Hooks.Audience) -> [String] {
        switch audience {
        case .runtime:
            guard !runtime.isEmpty else { return [] }
            let cName = Mpd.Runtime.containerName(runtime)
            return Mpd.Podman.running(cName) ? [cName] : []
        case .database:
            guard !dbEngine.isEmpty else { return [] }
            let cName = Mpd.Runtime.DB.containerName(engine: dbEngine, version: dbVersion)
            return Mpd.Podman.running(cName) ? [cName] : []
        case .service:
            return Mpd.Hooks.runningContainers(for: audience)
        }
    }
}
