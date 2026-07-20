// mpd lifecycle command hooks
// VM start behavior.

import Foundation

extension Mpd.Action.Start {
    static func preflight(in command: GlobalCommand, machineName _: String) throws {
        _ = command
        try CommandPreflight.check(commandName: "mpd --start", requiredNames: [
            "podman", "sudo", "bash", "ping", "sha256sum",
        ])
    }

    static func execute() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Mpd.VM.stateDir) else {
            throw RuntimeError("mpd is not set up yet. Run: mpd --setup")
        }

        // Ensure core services are running. fileaccess first — internal volume
        // ops (rescan, certs, etc.) on later boots may want it available.
        try Mpd.Service.FileAccess.start()

        // Refresh the published addressing before anything reads it — a VM
        // whose ID changed since last boot must not leave stale URLs behind.
        Mpd.VM.DataVolume.writeVMMeta()

        try Mpd.Service.Dnsmasq.start()
        try Mpd.Service.Portal.start()
        try Mpd.Service.Adminer.start()

        // Verify DNS resolution health.
        step("DNS resolution")
        Mpd.VM.DNS.verifyDNS()

        // Restore runtimes that had running projects before the last shutdown.
        let runtimesToRestore = Set(
            Mpd.Runtime.State.loadProjects().projects
                .filter { $0.requested == .running && !$0.runtimeName.isEmpty }
                .map { $0.runtimeName }
        )
        for runtimeName in runtimesToRestore.sorted() {
            let cName = Mpd.Runtime.containerName(runtimeName)
            guard Mpd.Podman.exists(cName), !Mpd.Podman.running(cName) else { continue }
            step("Restoring runtime '\(runtimeName)'")
            do {
                try Mpd.Runtime.start(runtimeName)
            } catch {
                print("  Warning: could not restore runtime '\(runtimeName)': \(error)")
            }
        }

        // Refresh the live-state snapshot (current-state.json) for
        // out-of-process consumers (portal, runtime tools).
        Mpd.Runtime.State.refreshCurrentStateCache()

        print("""

        \u{001B}[1;32m✓ mpd started.\u{001B}[0m

          https://\(Mpd.Net.zone)/
          mpd list              show all projects
          mpd start <project>   start a project
        """)
    }
}
