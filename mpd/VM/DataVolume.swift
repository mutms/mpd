// mpd — Mpd.VM.DataVolume namespace
// Data volume operations: rescan.

import Foundation

extension Mpd.VM.DataVolume {

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

    /// Write `/srv/meta/vm.json` — this VM's addressing facts, published into
    /// the data volume so container-side scripts can read them.
    ///
    /// Containers cannot read `/var/lib/mpd/conf/platform.env`: that directory
    /// holds the CA key and is deliberately never bind-mounted. But every
    /// container mounts the data volume at `/srv/`, so this is the one place
    /// a runtime script can learn the zone it should be composing URLs in.
    /// `assets/runtime-base/lib/source-mpd-env.sh` reads it and exports
    /// `MPD_ZONE` / `MPD_VM_ID`.
    ///
    /// Rewritten on every `--setup` and `--start`, so a VM that changes ID
    /// (hostname change, re-clone) converges on the next lifecycle command.
    static func writeVMMeta() {
        let meta: [String: Any] = [
            "vmId":       Mpd.Net.vmId,
            "zone":       Mpd.Net.zone,
            "subnet":     Mpd.Net.subnet,
            "gateway":    Mpd.Net.gateway,
            "dnsmasqIp":  Mpd.Service.Dnsmasq.ip,
        ]
        guard let json = try? JSONSerialization.data(
            withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) else { return }

        // Two audiences, two mount namespaces, same bytes:
        //  - runtime containers mount the data volume at /srv/ → /srv/meta/vm.json
        //  - the portal mounts the state dir at /mpd-state RO → /mpd-state/vm.json
        // Neither can see the other's path, and neither may see conf/.
        _ = Mpd.Podman.volumeToolRunWithInput(
            command: ["bash", "-c", "mkdir -p /srv/meta && cat > /srv/meta/vm.json"],
            input: json
        )
        try? json.write(to: URL(fileURLWithPath: "\(Mpd.VM.stateDir)/vm.json"), options: .atomic)
    }

    /// Read /srv/meta/*/project.json from the volume and rebuild the projects.json cache.
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
                    requested: .stopped
                ))
            }
        }
        cache.projects = newProjects
        Mpd.Runtime.State.saveProjects(cache)
        ok("Rescanned \(newProjects.count) project(s) from data volume.")
    }
}
