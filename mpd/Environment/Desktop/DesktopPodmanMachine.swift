// mpd — Podman machine lifecycle for desktop (macOS host + Podman Desktop).

import Foundation

extension Mpd.Environment.PodmanMachine {
    struct MachineInfo {
        let name: String
        let running: Bool
        let active: Bool
    }

    private static func podmanCapture(_ args: [String], suppressStderr: Bool = false) -> (Int32, String) {
        #if os(macOS)
        Mpd.Environment.HostExec.capture(["podman"] + args, suppressStderr: suppressStderr)
        #else
        Mpd.Environment.HostExec.capture(["podman"] + args, suppressStderr: suppressStderr, useSudo: true)
        #endif
    }

    @discardableResult
    private static func podmanRun(_ args: [String]) -> Int32 {
        #if os(macOS)
        Mpd.Environment.HostExec.run(["podman"] + args)
        #else
        Mpd.Environment.HostExec.run(["podman"] + args, useSudo: true)
        #endif
    }

    #if os(macOS)
    static func machineList() -> [MachineInfo] {
        let (rc, out) = podmanCapture(
            ["machine", "list", "--format", "{{.Name}}\t{{.Running}}\t{{.LastUp}}"],
            suppressStderr: true)
        guard rc == 0 else { return [] }

        let (rc2, json) = podmanCapture(["machine", "list", "--format", "json"], suppressStderr: true)
        guard rc2 == 0,
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return out.split(separator: "\n").compactMap { line in
                let cols = line.split(separator: "\t")
                guard cols.count >= 2 else { return nil }
                return MachineInfo(name: String(cols[0]), running: String(cols[1]) == "true", active: false)
            }
        }

        return arr.compactMap { obj in
            guard let name = obj["Name"] as? String else { return nil }
            return MachineInfo(
                name: name,
                running: (obj["Running"] as? Bool) ?? false,
                active: (obj["Active"] as? Bool) ?? false
            )
        }
    }

    @discardableResult
    static func machineStart(_ name: String) -> Int32 { podmanRun(["machine", "start", name]) }

    @discardableResult
    static func machineStop(_ name: String) -> Int32 { podmanRun(["machine", "stop", name]) }

    @discardableResult
    static func machineInit(name: String, memoryMB: Int, diskGB: Int, rootful: Bool = true) -> Int32 {
        var args = ["machine", "init", "--memory", "\(memoryMB)", "--disk-size", "\(diskGB)"]
        if rootful { args.append("--rootful") }
        args.append(name)
        return podmanRun(args)
    }

    @discardableResult
    static func setDefaultConnection(_ connection: String) -> Int32 {
        podmanRun(["system", "connection", "default", connection])
    }
    #else
    static func machineList() -> [MachineInfo] { [] }

    @discardableResult
    static func machineStart(_ name: String) -> Int32 { 1 }

    @discardableResult
    static func machineStop(_ name: String) -> Int32 { 1 }

    @discardableResult
    static func machineInit(name: String, memoryMB: Int, diskGB: Int, rootful: Bool = true) -> Int32 { 1 }

    @discardableResult
    static func setDefaultConnection(_ connection: String) -> Int32 { 1 }
    #endif

    @discardableResult
    static func setDefaultConnectionForMachine(_ name: String) -> Int32 {
        setDefaultConnection("\(name)-root")
    }

    static func activeMachine() -> String? {
        machineList().first(where: { $0.active })?.name
    }

    static func machineIsActiveAndRunning(_ name: String) -> Bool {
        guard let m = machineList().first(where: { $0.name == name }) else { return false }
        return m.running && m.active
    }

    /// Environment-level summary for status output.
    static func statusMachineLine() -> String? {
        #if os(macOS)
        let machines = machineList()
        let cfgMachine = Mpd.Core.State.activeMachine()
        guard !machines.isEmpty else { return nil }
        let selected = machines.first(where: { $0.name == cfgMachine }) ?? machines.first
        guard let m = selected else { return nil }
        let mStatus = m.running ? (m.active ? "running" : "running (not active)") : "stopped"
        let mHint = m.running ? "" : "  ← start with: podman machine start \(m.name)"
        return "Podman machine:  \(m.name)   \(mStatus)\(mHint)"
        #else
        return nil
        #endif
    }

    /// True when runtime engine is reachable for project/runtime operations.
    static func hostEngineRunning() -> Bool {
        #if os(macOS)
        let cfgMachine = Mpd.Core.State.activeMachine()
        return machineList().first(where: { $0.name == cfgMachine })?.running ?? false
        #else
        return true
        #endif
    }

    /// List project directories present in data volume but missing in projects cache.
    static func unregisteredProjectDirectories(knownNames: Set<String>) -> [String] {
        guard hostEngineRunning() else { return [] }
        let (_, dirsOut) = Mpd.Podman.volumeToolOutput(
            readOnly: true,
            command: ["bash", "-c", "ls -1 /srv/projects/ 2>/dev/null || true"],
            suppressStderr: true
        )
        return dirsOut.split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty && !knownNames.contains($0) }
            .sorted()
    }

    /// mpd-desktop machine names: bare `mpd-desktop` or `mpd-desktop-<suffix>`
    /// where suffix is lowercase alphanumerics. Strict by design — branding +
    /// guard against `mpd --start`/`--stop` accidentally touching unrelated
    /// Podman machines on the host. Mirrors mpd-machine's `mpd-machine[-N]`.
    static func isValidMachineName(_ name: String) -> Bool {
        name.range(of: #"^mpd-desktop(-[a-z0-9]+)?$"#, options: .regularExpression) != nil
    }

    /// Adopt the currently-running mpd-desktop Podman machine as the active
    /// one. Called by `mpd --setup`. The dev creates and starts the machine
    /// in Podman Desktop themselves (mpd doesn't init machines); `--setup`
    /// just locks onto whatever's running and persists it as the active
    /// machine for `--start`/`--stop` to target.
    ///
    /// Adoption tiers — all assume the regex matches:
    /// - running == current activeMachine: silent continue
    /// - running has a `~/.mpd/machines/<name>/` dir from a prior `--setup`:
    ///   silent switch (we know this machine)
    /// - running is brand new to mpd: prompt for confirmation before
    ///   committing it as the active machine
    @discardableResult
    static func adoptRunningMpdDesktop() throws -> String {
        let machines = machineList()
        let running = machines.filter { $0.running }

        guard !running.isEmpty else {
            throw RuntimeError("""
            No Podman machine is running.
            Create and start a Podman machine named 'mpd-desktop' (or
            'mpd-desktop-<suffix>') in Podman Desktop, then re-run mpd --setup.
            """)
        }
        if running.count > 1 {
            let names = running.map { $0.name }.sorted().joined(separator: ", ")
            throw RuntimeError("""
            Multiple Podman machines are running: \(names).
            Podman Desktop only supports one active machine — stop all but
            the mpd-desktop machine and re-run mpd --setup.
            """)
        }

        let name = running[0].name
        guard isValidMachineName(name) else {
            throw RuntimeError("""
            Running Podman machine '\(name)' is not an mpd-desktop machine.
            Create one named 'mpd-desktop' (or 'mpd-desktop-<suffix>') in
            Podman Desktop and start it, then re-run mpd --setup.
            """)
        }

        let current = Mpd.Core.State.activeMachine()
        if name != current {
            let known = FileManager.default.fileExists(
                atPath: Mpd.Core.State.machineDir(name))
            if !known {
                print("Podman machine '\(name)' is new to mpd.")
                print("Adopt it as the active mpd-desktop machine? [y/N] ", terminator: "")
                let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                guard answer == "y" || answer == "yes" else {
                    throw RuntimeError("Adoption declined.")
                }
            } else if !current.isEmpty {
                print("Switching active mpd-desktop machine: \(current) → \(name)")
            }

            var status = Mpd.Core.State.readStatus()
            status.activeMachine = name
            Mpd.Core.State.writeStatus(status)
        }

        _ = setDefaultConnectionForMachine(name)
        ok("Podman machine '\(name)' is active.")
        return name
    }

    /// Start the persisted active mpd-desktop machine. Auto-stops a sibling
    /// `mpd-desktop-*` if the dev started one in Podman Desktop manually
    /// (Podman Desktop only runs one machine at a time anyway). Refuses to
    /// touch foreign (non-mpd-desktop) machines — those are the dev's
    /// problem to stop.
    static func start(_ machineName: String) throws {
        let machines = machineList()
        if let m = machines.first(where: { $0.name == machineName }), m.running {
            _ = setDefaultConnectionForMachine(machineName)
            ok("'\(machineName)' is already running.")
            return
        }
        if let other = machines.first(where: { $0.name != machineName && $0.running }) {
            if isValidMachineName(other.name) {
                print("Stopping sibling mpd-desktop machine '\(other.name)' first.")
                guard machineStop(other.name) == 0 else {
                    throw RuntimeError("Failed to stop sibling Podman machine '\(other.name)'.")
                }
            } else {
                throw RuntimeError("""
                A non-mpd Podman machine is running: '\(other.name)'.
                Stop it in Podman Desktop and re-run mpd --start.
                """)
            }
        }
        guard machineStart(machineName) == 0 else {
            throw RuntimeError("Failed to start '\(machineName)'.")
        }
        _ = setDefaultConnectionForMachine(machineName)
        ok("'\(machineName)' is running.")
    }

    static func stop(_ machineName: String) throws {
        let machines = machineList()
        if let m = machines.first(where: { $0.name == machineName }), m.running {
            print("Stopping machine '\(machineName)'")
            guard machineStop(machineName) == 0 else {
                throw RuntimeError("Failed to stop Podman Desktop machine '\(machineName)'.")
            }
            ok("'\(machineName)' was stopped.")
        } else {
            ok("'\(machineName)' is already stopped.")
        }
    }
}

extension Mpd.Environment.PodmanMachine {
    static func rebuildRuntimeStateEntryCache(quiet: Bool = false) {
        let containers = Mpd.Runtime.allContainers()

        // Prune stale runtime cache entries that no longer exist in Podman.
        let discoveredNames = Set(containers.compactMap { $0.Labels?["mpd.name"] }.filter { !$0.isEmpty })
        let cachedNames = Set(Mpd.Runtime.State.listRuntimeStateEntries().map { $0.name })
        for stale in cachedNames.subtracting(discoveredNames) {
            Mpd.Runtime.State.deleteRuntimeStateEntry(stale)
        }

        for item in containers {
            let n       = item.Labels?["mpd.name"]    ?? ""; guard !n.isEmpty else { continue }
            let runtime = item.Labels?["mpd.runtime"] ?? n
            let ip      = item.Labels?["mpd.ip"]      ?? Mpd.Podman.containerIP(item.Names.first ?? "")
            let status  = item.State == "running" ? "running" : "stopped"
            let meta    = RuntimeStateEntry(name: n, runtime: runtime, ip: ip, status: status)
            Mpd.Runtime.State.saveRuntimeStateEntry(meta)
        }
        guard !quiet else { return }
        if containers.isEmpty {
            ok("No runtimes found.")
        } else {
            ok("Runtime cache rebuilt (\(containers.count) runtime(s) found).")
        }
    }

    static func rebuildDatabaseStateCache(quiet: Bool = false) {
        let containers = Mpd.Podman.ps(filter: "label=mpd.type=db")
        let entries: [DatabaseStateEntry] = containers.compactMap { item in
            let databaseId = item.Labels?["mpd.name"] ?? ""
            let engine = item.Labels?["mpd.db.engine"] ?? ""
            let version = item.Labels?["mpd.db.version"] ?? ""
            guard !databaseId.isEmpty, !engine.isEmpty, !version.isEmpty else { return nil }
            let containerName = item.Names.first ?? "mpd-db-\(databaseId)"
            let status = item.State == "running" ? "running" : "stopped"
            return DatabaseStateEntry(
                databaseId: databaseId,
                engine: engine,
                version: version,
                containerName: containerName,
                status: status
            )
        }
        let sorted = entries.sorted { $0.databaseId < $1.databaseId }
        Mpd.Runtime.State.saveDatabases(RegisteredDatabases(databases: sorted))
        guard !quiet else { return }
        if sorted.isEmpty {
            ok("No databases found.")
        } else {
            ok("Database cache rebuilt (\(sorted.count) database(s) found).")
        }
    }
}
