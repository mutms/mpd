// mpd — Mpd.Core.DataVolume namespace
// Data volume operations: rescan.

import Foundation

extension Mpd.Core.DataVolume {

    // MARK: - Private helpers

    /// Find all running DB containers and return their names.
    private static func runningDbContainers() -> [String] {
        Mpd.Podman.ps(filter: "label=mpd.type=db")
            .filter { $0.State == "running" }
            .compactMap { $0.Names.first }
    }

    /// Stop running DB containers, returning the list of names that were stopped.
    private static func stopDbContainers() -> [String] {
        let running = runningDbContainers()
        for name in running {
            print("Stopping \(name)...")
            Mpd.Podman.stop(name)
        }
        return running
    }

    /// Restart previously stopped DB containers.
    private static func restartDbContainers(_ names: [String]) {
        for name in names {
            print("Restarting \(name)...")
            Mpd.Podman.start(name)
        }
    }

    // MARK: - Public operations

    /// Read /srv/meta/*/project.json from the volume and rebuild per-machine projects.json cache.
    static func rescan() throws {
        step("Scanning data volume for project metadata")
        let script = """
            result="["; first=1
            for f in /srv/meta/*/project.json; do
                [ -f "$f" ] || continue
                content=$(cat "$f")
                [ $first -eq 1 ] && result="$result$content" && first=0 || result="$result,$content"
            done
            echo "${result}]"
            """
        let (rc, output) = Mpd.Podman.volumeToolOutput(
            readOnly: true,
            name: "mpd-temp-rescan",
            command: ["bash", "-c", script],
            suppressStderr: true
        )
        guard rc == 0 else {
            print("Warning: Could not scan data volume (volume may be empty).")
            return
        }

        struct ProjectJson: Codable {
            var name: String?
            var type: String?
            var databaseEngine: String?
            var databaseVersion: String?
            var databaseId: String?
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "[]",
              let data = trimmed.data(using: .utf8),
              let entries = try? JSONDecoder().decode([ProjectJson].self, from: data) else {
            var cache = Mpd.Runtime.State.loadProjects()
            cache.projects = []
            Mpd.Runtime.State.saveProjects(cache)
            ok("No projects found.")
            return
        }

        var cache = Mpd.Runtime.State.loadProjects()
        let existingMap = Dictionary(uniqueKeysWithValues: cache.projects.map { ($0.name, $0) })
        var newProjects = [RegisteredProjectRecord]()
        for e in entries {
            guard let n = e.name, !n.isEmpty else { continue }
            if let existing = existingMap[n] {
                newProjects.append(existing)   // preserve status + runtimeName from cache
            } else {
                newProjects.append(RegisteredProjectRecord(
                    name: n,
                    type: e.type ?? "",
                    databaseId: e.databaseId ?? "",
                    databaseEngine: e.databaseEngine ?? "",
                    databaseVersion: e.databaseVersion ?? "",
                    runtimeName: "",
                    status: .stopped
                ))
            }
        }
        cache.projects = newProjects
        Mpd.Runtime.State.saveProjects(cache)
        ok("Rescanned \(newProjects.count) project(s) from data volume.")
    }
}
