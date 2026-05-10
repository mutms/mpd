// mpd — live "current" state accessors for runtimes, projects, and DBs.
//
// The persisted intent (`requested`) lives in RegisteredProjectRecord
// and RuntimeStateEntry — it's mutated only by explicit user verbs.
// The live observation (`current`) lives here — it's computed every
// time it's needed by querying podman, never persisted. See
// docs/HOOKS.md §"Resource lifecycle model" for the model.
//
// Display layers join the two: divergence (e.g. `requested=running,
// current=stopped` after a reboot but before `mpd --start`) becomes
// visible to the user, and the reconciliation step is legible.

import Foundation

enum RuntimeCurrent: String {
    /// Runtime container exists and is running.
    case running
    /// Runtime container exists but is stopped.
    case stopped
    /// Runtime container does not exist (never created, or deleted).
    case missing
}

enum ProjectCurrent: String {
    /// Project's runtime container is running and the project is registered.
    case running
    /// Project is registered but its runtime is stopped — project can't be live.
    case stopped
    /// Project record has no runtime, or the runtime container is gone.
    case missing
}

enum DbCurrent: String {
    /// DB container exists and is running.
    case running
    /// DB container exists but is stopped.
    case stopped
    /// DB container does not exist.
    case missing
}

extension Mpd.Runtime {
    /// Live observation of a runtime's container state.
    static func current(_ name: String) -> RuntimeCurrent {
        let cName = containerName(name)
        guard Mpd.Podman.exists(cName) else { return .missing }
        return Mpd.Podman.running(cName) ? .running : .stopped
    }
}

extension Mpd.Project {
    /// Live observation of a project's effective state, derived from
    /// the project's runtime + the persisted intent. The runtime's
    /// container is what actually hosts the project process(es).
    static func current(_ name: String) -> ProjectCurrent {
        guard let proj = Mpd.Runtime.State.getProject(name) else { return .missing }
        guard !proj.runtimeName.isEmpty else { return .missing }
        switch Mpd.Runtime.current(proj.runtimeName) {
        case .missing: return .missing
        case .stopped: return .stopped
        case .running:
            return proj.requested == .running ? .running : .stopped
        }
    }
}

extension Mpd.Runtime.DB {
    /// Live observation of a DB container's state. DBs have no
    /// `requested` (no persisted intent) — they're emergent from
    /// runtime + project records.
    static func current(engine: String, version: String) -> DbCurrent {
        let cName = containerName(engine: engine, version: version)
        guard Mpd.Podman.exists(cName) else { return .missing }
        return Mpd.Podman.running(cName) ? .running : .stopped
    }
}

// MARK: - current-state.json snapshot
//
// Out-of-process consumers — the portal container, in-runtime tools —
// don't have podman access, so they can't compute `current` themselves.
// We periodically snapshot live observations into
// `~/.mpd/machines/<m>/current-state.json` (mounted into the portal
// container at `/mpd-state/current-state.json`). The snapshot is
// refreshed on every `mpd list`, `mpd --status`, `mpd --start/--stop/
// --restart`, and the rebuild paths (`mpd --setup`).
//
// `requested` files (projects.json, runtimes/<n>/meta.json) are
// strictly persisted intent. `current-state.json` is strictly
// ephemeral observation. No mixing — readers consult whichever they
// need.

/// Snapshot of live container state at a point in time.
/// Keys are bare names (`php`, `moodle520`, `postgres-latest`); values
/// are the rawValue of the matching `*Current` enum
/// (`"running"` / `"stopped"` / `"missing"`).
struct CurrentStateSnapshot: Codable {
    /// ISO-8601 timestamp the snapshot was written.
    var refreshedAt: String
    var runtimes: [String: String]
    var projects: [String: String]
    var databases: [String: String]
}

extension Mpd.Runtime.State {
    /// Path to the live-state snapshot file for the active machine.
    /// Bind-mounted into the portal container at
    /// `/mpd-state/current-state.json`.
    static var currentStatePath: String {
        "\(Mpd.Core.State.machineDir())/current-state.json"
    }

    /// Refresh the live-state snapshot. Walks runtime metas, projects,
    /// and DB containers; writes one JSON file. Cheap (a few podman
    /// queries) — safe to call from list/status commands and at the end
    /// of state-mutating verbs.
    ///
    /// Best-effort: if the active machine isn't set or podman isn't
    /// reachable, silently skips. Never throws — diagnostic refresh
    /// must never block a user-visible action.
    static func refreshCurrentStateCache() {
        let machine = Mpd.Core.State.activeMachine()
        guard !machine.isEmpty else { return }

        var runtimes: [String: String] = [:]
        for entry in listRuntimeStateEntries() {
            runtimes[entry.name] = Mpd.Runtime.current(entry.name).rawValue
        }

        var projects: [String: String] = [:]
        for proj in loadProjects().projects {
            projects[proj.name] = Mpd.Project.current(proj.name).rawValue
        }

        var databases: [String: String] = [:]
        for item in Mpd.Podman.ps(filter: "label=mpd.type=db") {
            guard let id = item.Labels?["mpd.name"], !id.isEmpty else { continue }
            databases[id] = item.State == "running" ? "running" : "stopped"
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let snapshot = CurrentStateSnapshot(
            refreshedAt: formatter.string(from: Date()),
            runtimes: runtimes,
            projects: projects,
            databases: databases
        )

        JSONStateStore.writeJSON(snapshot, to: currentStatePath)

        // Regenerate ~/.mpd/links/<ide>/ alongside the snapshot — same
        // cadence as the live-state JSON, self-healing across create /
        // delete / runtime moves. Best-effort: errors are swallowed
        // inside refresh().
        Mpd.Runtime.IdeLinks.refresh()
    }
}
