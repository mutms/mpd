// mpd lifecycle command hooks
// In-VM status rendering.

import Foundation

extension Mpd.Action.Status {
    static func execute() throws {
        guard FileManager.default.fileExists(atPath: Mpd.VM.varLibDir) else {
            print("""
                mpd is not set up on this machine.

                To get started:
                  1. Build: make install
                  2. Run: mpd --setup
                """)
            return
        }

        print("mpd  —  Moodle Plugin Development Environment\n")

        let cache = Mpd.Runtime.State.loadProjects()
        let runtimes = Mpd.Runtime.allContainers()

        var projectsByRuntime: [String: [RegisteredProjectRecord]] = [:]
        for p in cache.projects {
            if !p.runtimeName.isEmpty { projectsByRuntime[p.runtimeName, default: []].append(p) }
        }

        let runtimeNames = runtimes.compactMap { $0.Labels?["mpd.name"] }.sorted()
        for n in runtimeNames {
            let item = runtimes.first { $0.Labels?["mpd.name"] == n }
            let running = item?.State == "running"
            let status = running ? "running" : "stopped"
            print("\n\(n)  \(status)  ssh \(n).runtime.mpd.test")

            let projs = (projectsByRuntime[n] ?? []).sorted(by: { $0.name < $1.name })
            for p in projs {
                let url = p.requested == .running ? "   https://\(p.name).mpd.test/" : ""
                print("  \(p.name)   \(p.requested)\(url)")
            }
        }

        let existingRuntimes = Set(runtimeNames)
        let allOrphaned = cache.projects.filter {
            $0.runtimeName.isEmpty || (!$0.runtimeName.isEmpty && !existingRuntimes.contains($0.runtimeName))
        }
        if !allOrphaned.isEmpty {
            print("\nOrphaned projects without runtime:")
            for p in allOrphaned.sorted(by: { $0.name < $1.name }) {
                print("  \(p.name.padding(toLength: 16, withPad: " ", startingAt: 0))" +
                      "\(p.requested.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0))" +
                      "→ mpd \(p.name) start")
            }
        }

        let knownNames = Set(cache.projects.map { $0.name })
        let unregistered = Mpd.Runtime.unregisteredProjectDirectories(knownNames: knownNames)
        if !unregistered.isEmpty {
            print("\nUnregistered project directories:")
            for name in unregistered {
                print("  \(name.padding(toLength: 24, withPad: " ", startingAt: 0))" +
                      "→ mpd \(name) create")
            }
        }

        print("\n  mpd --help                full flag reference")
    }
}
