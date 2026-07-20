// mpd — Mpd.Hooks namespace
//
// Engine for the publish/subscribe hook system. Verb handlers fire
// typed Events; bash hook scripts at hooks/<event-name>.d/ inside
// container assets subscribe. See docs/HOOKS.md for vocabulary, the
// resource lifecycle model, the v1 event catalogue, and the
// acceptance test.
//
// Vocabulary:
//   Event    — Swift class declared per fire-point
//   Hook     — bash script that observes an event, lives on disk
//   Audience — list of container kinds an event reaches
//
// Adding an event: define `struct EventXxxYyy: Mpd.Hooks.Event` with
// the audience list, env vars, and failure mode. Call
// `try Mpd.Hooks.fire(EventXxxYyy(...))` from the verb handler. Drop
// hook scripts under the matching `hooks/<event-name>.d/` directory in
// the right asset layer.

import Foundation

extension Mpd {
    enum Hooks {}
}

// MARK: - Audience

extension Mpd.Hooks {
    /// Container kinds an event can reach. The dispatcher delivers an
    /// event to every running container of the given kind.
    enum Audience: Equatable {
        case runtime
        case database
        case service(String)
    }

    /// Failure semantics for an event class.
    enum FailureMode {
        /// Hook failure aborts the firing verb. Use for pre-conditions
        /// (e.g. "ensure DB is up before project start").
        case abort
        /// Hook failure logs but the verb proceeds. Use for cleanup-style
        /// and post-state events ("you can't fail to stop").
        case `continue`
    }
}

// MARK: - Event protocol

extension Mpd.Hooks {
    /// An Event is a typed Swift class declared per fire-point. Verbs
    /// construct an Event with relevant context and call `Mpd.Hooks.fire`.
    protocol Event {
        /// Event name in kebab-case. Auto-derived from the type name by
        /// stripping the `Event` prefix and converting to kebab-case.
        /// `EventProjectPreStart` → `project-pre-start`.
        static var name: String { get }

        /// Bumped when the env-var contract or audience list changes
        /// in a way that hooks should review. Diagnostics flag a bump
        /// at the next `mpd --setup`.
        static var revision: Int { get }

        /// Container kinds this event is delivered to.
        static var audiences: [Audience] { get }

        /// What happens to the firing verb when a hook script exits non-zero.
        static var onFailure: FailureMode { get }

        /// Per-script timeout. Default 30 s.
        static var timeout: TimeInterval { get }

        /// Event-specific context surfaced to hook scripts as
        /// `MPD_HOOK_<KEY>` env vars. Three standard vars
        /// (`MPD_HOOK_EVENT`, `MPD_HOOK_REVISION`, `MPD_HOOK_VERB`) are
        /// added by the dispatcher; this method provides only the typed
        /// extras specific to this event.
        var env: [String: String] { get }

        /// Containers reached by this event for a given audience. Default
        /// implementation enumerates all running containers of the audience
        /// kind (used by mpd-level events). Project-level events override
        /// to return just the project's runtime / DB.
        func containers(for audience: Audience) -> [String]
    }
}

// MARK: - Event default implementations

extension Mpd.Hooks.Event {
    static var name: String { Mpd.Hooks.derivedEventName(Self.self) }
    static var revision: Int { 1 }
    static var timeout: TimeInterval { 30 }

    func containers(for audience: Mpd.Hooks.Audience) -> [String] {
        Mpd.Hooks.runningContainers(for: audience)
    }
}

// MARK: - Name derivation

extension Mpd.Hooks {
    /// `EventProjectPreStart` → `project-pre-start`.
    static func derivedEventName<T>(_ type: T.Type) -> String {
        let typeName = String(describing: type)
        let stripped = typeName.hasPrefix("Event") ? String(typeName.dropFirst(5)) : typeName
        return kebabCase(stripped)
    }

    /// `MpdPreStop` → `mpd-pre-stop`.
    /// Inserts a hyphen before any uppercase letter that's preceded by
    /// a lowercase letter; lowercases the result.
    static func kebabCase(_ s: String) -> String {
        var out = ""
        let chars = Array(s)
        for i in 0..<chars.count {
            let ch = chars[i]
            if i > 0, ch.isUppercase, chars[i - 1].isLowercase {
                out.append("-")
            }
            out.append(ch)
        }
        return out.lowercased()
    }
}

// MARK: - Audience → running containers

extension Mpd.Hooks {
    /// Default audience → running container resolution. Used by the
    /// `Event` protocol's default `containers(for:)`. Project-level
    /// events override to scope to a single container.
    static func runningContainers(for audience: Audience) -> [String] {
        switch audience {
        case .runtime:
            return Mpd.Podman.ps(filter: "label=mpd.runtime")
                .filter { $0.State == "running" }
                .compactMap { $0.Names.first }
        case .database:
            return Mpd.Podman.ps(filter: "label=mpd.type=db")
                .filter { $0.State == "running" }
                .compactMap { $0.Names.first }
        case .service(let name):
            let cName = "mpd-service-\(name)"
            return Mpd.Podman.running(cName) ? [cName] : []
        }
    }
}

// MARK: - Fire dispatcher

extension Mpd.Hooks {
    /// Fire an event. Enumerates audience containers, invokes hook
    /// scripts in numeric-prefix order via `podman exec`, applies the
    /// event's failure mode.
    ///
    /// Throws when any `.abort`-mode hook fails. `.continue`-mode failures
    /// are logged but don't propagate.
    static func fire<E: Event>(_ event: E, verb: String = "") throws {
        let eventName = E.name
        var aborted: Error?

        for audience in E.audiences {
            let containers = event.containers(for: audience)
            for container in containers {
                do {
                    try fireOne(
                        event: event,
                        eventName: eventName,
                        audience: audience,
                        container: container,
                        verb: verb
                    )
                } catch {
                    if E.onFailure == .abort {
                        aborted = error
                        break
                    }
                    // .continue: fireOne already printed ✗ — keep going.
                }
            }
            if aborted != nil { break }
        }
        if let aborted { throw aborted }
    }

    /// Run all hook scripts for one event on one container.
    private static func fireOne<E: Event>(
        event: E,
        eventName: String,
        audience: Audience,
        container: String,
        verb: String
    ) throws {
        let scripts = (try? discoverScripts(audience: audience, container: container, eventName: eventName)) ?? []
        guard !scripts.isEmpty else { return }

        // Standard env vars + event-specific extras, all prefixed MPD_HOOK_.
        var podmanOptions: [String] = []
        var envVars: [String: String] = [
            "MPD_HOOK_EVENT": eventName,
            "MPD_HOOK_REVISION": String(E.revision),
            "MPD_HOOK_VERB": verb,
        ]
        for (k, v) in event.env {
            envVars["MPD_HOOK_\(k)"] = v
        }
        for (k, v) in envVars {
            podmanOptions.append("--env")
            podmanOptions.append("\(k)=\(v)")
        }

        for script in scripts {
            let label = "[\(container)] \(eventName)/\(script.basename)"
            let started = Date()
            // Enforced, not just declared: a hook that never returns
            // would otherwise hang the verb that fired it — and for
            // mpd-pre-stop, hang VM shutdown.
            let rc = Mpd.Podman.execWithTimeout(container, options: podmanOptions,
                                                ["bash", script.containerPath],
                                                timeout: E.timeout)
            let elapsed = Int(Date().timeIntervalSince(started))
            if rc == 0 {
                print("  \(label) ✓ (\(elapsed)s)")
            } else if rc == Mpd.VM.exitTimedOut {
                print("  \(label) ✗ timed out after \(Int(E.timeout))s")
                throw RuntimeError(
                    "Hook \(eventName) timed out on \(container) after \(Int(E.timeout))s")
            } else {
                print("  \(label) ✗ exit \(rc) (\(elapsed)s)")
                throw RuntimeError("Hook \(eventName) failed on \(container) (exit \(rc))")
            }
        }
    }
}

// MARK: - Script discovery

extension Mpd.Hooks {
    fileprivate struct DiscoveredScript {
        /// Filename only — e.g. `10-graceful-stop`.
        let basename: String
        /// Path inside the container — e.g.
        /// `/opt/mpd/assets/databases/postgres/hooks/mpd-pre-stop.d/10-graceful-stop`.
        let containerPath: String
    }

    /// Walk asset directories for hook scripts matching this event +
    /// container. Layered: base → runtime → type for runtimes; per-engine
    /// for databases. Returns scripts in execution order (layer first,
    /// then alphabetical within a directory — numeric prefixes order
    /// scripts inside a single layer).
    fileprivate static func discoverScripts(
        audience: Audience,
        container: String,
        eventName: String
    ) throws -> [DiscoveredScript] {
        let assets = try Mpd.VM.assetsPath()
        var dirs: [(hostDir: String, containerDir: String)] = []

        switch audience {
        case .runtime:
            // Runtime containers have `<assets>:/opt/mpd/assets:ro` bind-mounted.
            // Layered: base + per-runtime. Type-level layer (per-project)
            // is project-event territory and not yet wired in v1.
            dirs.append((
                "\(assets)/runtime-base/hooks/\(eventName).d",
                "/opt/mpd/assets/runtime-base/hooks/\(eventName).d"
            ))
            let runtimeName = Mpd.Podman.label(container, "mpd.name")
            if !runtimeName.isEmpty {
                dirs.append((
                    "\(assets)/runtimes/\(runtimeName)/hooks/\(eventName).d",
                    "/opt/mpd/assets/runtimes/\(runtimeName)/hooks/\(eventName).d"
                ))
            }
        case .database:
            // DB containers get the same `<assets>:/opt/mpd/assets:ro` bind
            // mount — added in `Mpd.Runtime.DB.ensure`. Per-engine only;
            // there's no `database-base` layer (DB images are stock).
            let engine = Mpd.Podman.label(container, "mpd.db.engine")
            if !engine.isEmpty {
                dirs.append((
                    "\(assets)/databases/\(engine)/hooks/\(eventName).d",
                    "/opt/mpd/assets/databases/\(engine)/hooks/\(eventName).d"
                ))
            }
        case .service(let name):
            dirs.append((
                "\(assets)/services/\(name)/hooks/\(eventName).d",
                "/opt/mpd/assets/services/\(name)/hooks/\(eventName).d"
            ))
        }

        var scripts: [DiscoveredScript] = []
        let fm = FileManager.default
        for (hostDir, containerDir) in dirs {
            guard fm.fileExists(atPath: hostDir) else { continue }
            let names = (try? fm.contentsOfDirectory(atPath: hostDir)) ?? []
            for n in names.sorted() {
                // Only `*.sh`. Without an extension filter every file in
                // the directory is executed — an editor backup
                // (`10-foo.sh~`), a `.bak`, a stray `.swp`, or a README
                // would all be run through bash. Requiring the extension
                // makes "is this a hook?" answerable by looking, and a
                // hook that needs a compiled helper just execs it from a
                // one-line wrapper.
                guard n.hasSuffix(".sh") else { continue }
                let host = "\(hostDir)/\(n)"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: host, isDirectory: &isDir),
                      !isDir.boolValue else { continue }
                scripts.append(DiscoveredScript(
                    basename: n,
                    containerPath: "\(containerDir)/\(n)"
                ))
            }
        }
        return scripts
    }
}
