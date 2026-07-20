// mpd — GlobalCommand handle* methods (pure CLI dispatch layer)
// Each handler delegates to the owning Mpd.* namespace — no business logic here.
// Setup/start/stop command handlers live in CLI/CommandHandlers/Command*.swift.

import Foundation

// MARK: - Runtime flag handlers
//
// Listing handlers (projects / runtimes / services / dbs) live on the
// `list` verb (ListSubcommand in main.swift), not on GlobalCommand.

extension GlobalCommand {

    func handleRuntimeShow(_ name: String) throws {
        try Mpd.Runtime.show(name)
    }

    func handleRuntimeCreate(_ name: String) throws {
        try Mpd.Runtime.create(name: name)
    }

    func handleRuntimeStart(_ name: String) throws {
        try Mpd.Runtime.start(name)
    }

    func handleRuntimeStop(_ name: String) throws {
        try Mpd.Runtime.stop(name)
    }

    func handleRuntimeDelete(_ name: String) throws {
        try Mpd.Runtime.delete(name, skipPrompt: yes)
    }

}

// MARK: - DB flag handlers

extension GlobalCommand {

    private func syncDatabaseStateCache() {
        Mpd.Runtime.DB.rebuildStateCache(quiet: true)
        try? Mpd.Service.Dnsmasq.ensureReadyForServiceResolution()
    }

    func handleDbCreate(_ input: String) throws {
        let (engine, version, _) = try Mpd.Runtime.DB.resolve(input)
        try Mpd.Runtime.DB.ensure(engine: engine, version: version)
        syncDatabaseStateCache()
    }

    func handleDbStart(_ input: String) throws {
        let (engine, _, cName) = try Mpd.Runtime.DB.resolve(input)
        guard Mpd.Podman.exists(cName) else {
            throw RuntimeError("DB container '\(cName)' does not exist. Use --db-create to create it.")
        }
        guard !Mpd.Podman.running(cName) else {
            print("\(cName) is already running.")
            syncDatabaseStateCache()
            return
        }
        guard Mpd.Podman.start(cName) == 0 else { throw RuntimeError("Failed to start '\(cName)'.") }
        try Mpd.Runtime.DB.waitFor(engine: engine, container: cName)
        ok("\(cName) is running.")
        syncDatabaseStateCache()
    }

    func handleDbStop(_ input: String) throws {
        let (_, _, cName) = try Mpd.Runtime.DB.resolve(input)
        guard Mpd.Podman.exists(cName) else {
            throw RuntimeError("DB container '\(cName)' does not exist.")
        }
        guard Mpd.Podman.running(cName) else {
            print("\(cName) is already stopped.")
            syncDatabaseStateCache()
            return
        }
        guard Mpd.Podman.stop(cName) == 0 else { throw RuntimeError("Failed to stop '\(cName)'.") }
        ok("\(cName) stopped.")
        syncDatabaseStateCache()
    }

    func handleDbDelete(_ input: String) throws {
        let (engine, version, cName) = try Mpd.Runtime.DB.resolve(input)
        guard Mpd.Podman.exists(cName) else { throw RuntimeError("DB container '\(cName)' does not exist.") }

        // The data directory goes with the container — consistent with
        // `mpd delete <project>`, which removes the DB, dataroot, source
        // and config together.
        let databaseId = Mpd.Runtime.DB.shortName(engine: engine, version: version)
        let dataDir = Mpd.Runtime.DB.dataDir(engine: engine, version: version)

        // A DB container is shared by every project using that
        // engine:version, so this is rarely a one-project decision. Name
        // the projects that lose their data rather than describing the
        // blast radius abstractly.
        let users = Mpd.Runtime.State.loadProjects().projects
            .filter { $0.databaseId == databaseId }
            .map { $0.name }
            .sorted()

        print("Container: \(cName)")
        print("Data:      \(dataDir)/")
        if users.isEmpty {
            print("This will remove the container and every database in it.")
        } else {
            print("In use by: \(users.joined(separator: ", "))")
            print("This will remove the container and every database in it — \(users.count) project(s) will lose their data.")
        }

        guard yes || promptYesNo("Remove DB container '\(cName)' and all its data?") else { print("Aborted."); return }
        Mpd.Podman.stop(cName)
        guard Mpd.Podman.remove(cName) == 0 else { throw RuntimeError("Failed to remove '\(cName)'.") }
        // After the container, so a failed removal doesn't orphan data
        // whose owner still exists. Failure is reported, not swallowed —
        // a destructive verb must not claim success for work it skipped.
        guard Mpd.Podman.volumeToolRemoveAll(dataDir) else {
            throw RuntimeError("Removed container '\(cName)' but failed to remove \(dataDir)/. Remove it by hand.")
        }
        ok("'\(cName)' and \(dataDir)/ removed.")
        syncDatabaseStateCache()
    }
}

// (Service listing is on the `list` verb — see ListSubcommand in main.swift.)
