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
        let (_, _, cName) = try Mpd.Runtime.DB.resolve(input)
        guard Mpd.Podman.exists(cName) else { throw RuntimeError("DB container '\(cName)' does not exist.") }
        guard yes || promptYesNo("Remove DB container '\(cName)'?") else { print("Aborted."); return }
        Mpd.Podman.stop(cName)
        guard Mpd.Podman.remove(cName) == 0 else { throw RuntimeError("Failed to remove '\(cName)'.") }
        ok("'\(cName)' removed.")
        syncDatabaseStateCache()
    }
}

// (Service listing is on the `list` verb — see ListSubcommand in main.swift.)
