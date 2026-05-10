// mpd — Mpd.Hooks diagnostic engine
//
// Runs on `mpd --setup` (and on demand via `mpd --check-hooks`). Walks
// asset hook directories, cross-references against the Swift Event
// catalogue, and warns on three classes of issue:
//
//   1. Orphan hook (event removed)   — `hooks/<unknown>.d/` exists
//   2. Orphan hook (audience removed) — event still exists but the
//                                      layer's container kind is no
//                                      longer in event.audiences
//   3. Revision bump                  — event.revision increased since
//                                      the last `mpd --setup` run
//
// Diagnostics are warnings, never hard failures — orphan hooks just
// don't fire. Stamps the per-event revision into
// `~/.mpd/hooks-state.json` so revision-bump detection survives across
// runs. See docs/HOOKS.md §"Diagnostics".

import Foundation

extension Mpd.Hooks {

    // MARK: - Catalogue

    /// Type-erased metadata about an Event class — name, revision, audiences.
    /// Used by the diagnostic engine to cross-reference asset directories
    /// against what Swift knows.
    struct EventCatalogueEntry {
        let name: String
        let revision: Int
        let audiences: [Audience]

        init<E: Event>(_ type: E.Type) {
            self.name = E.name
            self.revision = E.revision
            self.audiences = E.audiences
        }
    }

    /// All v1 events. **Add new events here when introduced.** The
    /// diagnostic engine treats anything not in this list as an orphan.
    static let catalogue: [EventCatalogueEntry] = [
        .init(EventMpdPreStop.self),
        .init(EventProjectPreStart.self),
        .init(EventProjectPreStop.self),
        .init(EventProjectPostStart.self),
    ]

    // MARK: - State file (revision tracking)

    private static var stateFilePath: String {
        "\(Mpd.Environment.dotMpdDir)/hooks-state.json"
    }

    private struct State: Codable {
        var revisions: [String: Int] = [:]
    }

    private static func loadState() -> State {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: stateFilePath)),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return State() }
        return state
    }

    private static func writeState(_ state: State) {
        let dir = Mpd.Environment.dotMpdDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: stateFilePath))
    }

    // MARK: - Diagnose

    /// Walk asset hook directories, cross-reference against the catalogue,
    /// print warnings for orphans and revision bumps. Always returns;
    /// never throws or aborts. Stamps the current revisions for next run.
    static func diagnose() {
        guard let assets = try? Mpd.Core.Assets.path() else { return }

        let byName: [String: EventCatalogueEntry] =
            Dictionary(uniqueKeysWithValues: catalogue.map { ($0.name, $0) })

        var warnings: [String] = []

        // Orphan + audience checks: walk every layer directory's hooks/.
        for found in walkHookDirs(assets: assets) {
            guard let entry = byName[found.eventName] else {
                warnings.append(
                    "Hook for unknown event '\(found.eventName)' at \(found.relativePath); " +
                    "remove or move."
                )
                continue
            }
            if !entry.audiences.contains(where: { matches(audience: $0, kind: found.kind) }) {
                warnings.append(
                    "Hook at \(found.relativePath) subscribes to event '\(found.eventName)' " +
                    "but the event no longer fires on this audience."
                )
            }
        }

        // Revision bumps: compare current event revisions against last seen.
        var state = loadState()
        for entry in catalogue {
            let last = state.revisions[entry.name]
            if let last, last != entry.revision {
                warnings.append(
                    "Event '\(entry.name)' revised (rev \(last) → rev \(entry.revision)); " +
                    "review hooks under hooks/\(entry.name).d/ for changed env vars."
                )
            }
            state.revisions[entry.name] = entry.revision
        }
        writeState(state)

        guard !warnings.isEmpty else { return }
        errPrint("")
        errPrint("Hook diagnostics:")
        for w in warnings { errPrint("  • \(w)") }
    }

    // MARK: - Walking asset hook dirs

    fileprivate struct FoundHookDir {
        /// Container kind this layer maps to.
        let kind: AudienceKind
        /// Event name (the `<name>` in `<name>.d/`).
        let eventName: String
        /// Asset-relative path for display (e.g.
        /// `assets/databases/postgres/hooks/mpd-pre-stop.d`).
        let relativePath: String
    }

    fileprivate enum AudienceKind {
        case runtime
        case database
        case service
    }

    fileprivate static func matches(audience: Audience, kind: AudienceKind) -> Bool {
        switch (audience, kind) {
        case (.runtime, .runtime): return true
        case (.database, .database): return true
        case (.service, .service): return true
        default: return false
        }
    }

    fileprivate static func walkHookDirs(assets: String) -> [FoundHookDir] {
        var results: [FoundHookDir] = []
        let fm = FileManager.default

        // Runtime base
        results += scan(
            dir: "\(assets)/runtime-base/hooks",
            relative: "assets/runtime-base/hooks",
            kind: .runtime
        )
        // Per-runtime
        for sub in (try? fm.contentsOfDirectory(atPath: "\(assets)/runtimes")) ?? [] {
            results += scan(
                dir: "\(assets)/runtimes/\(sub)/hooks",
                relative: "assets/runtimes/\(sub)/hooks",
                kind: .runtime
            )
        }
        // Per-database-engine
        for sub in (try? fm.contentsOfDirectory(atPath: "\(assets)/databases")) ?? [] {
            results += scan(
                dir: "\(assets)/databases/\(sub)/hooks",
                relative: "assets/databases/\(sub)/hooks",
                kind: .database
            )
        }
        // Per-service
        for sub in (try? fm.contentsOfDirectory(atPath: "\(assets)/services")) ?? [] {
            results += scan(
                dir: "\(assets)/services/\(sub)/hooks",
                relative: "assets/services/\(sub)/hooks",
                kind: .service
            )
        }
        return results
    }

    fileprivate static func scan(dir: String, relative: String, kind: AudienceKind) -> [FoundHookDir] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir) else { return [] }
        let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        return names.compactMap { n in
            guard n.hasSuffix(".d") else { return nil }
            let eventName = String(n.dropLast(2))
            return FoundHookDir(
                kind: kind,
                eventName: eventName,
                relativePath: "\(relative)/\(n)"
            )
        }
    }
}
