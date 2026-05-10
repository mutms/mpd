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
