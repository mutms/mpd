// mpd-machine command hooks
// Linux runtime / mpd-machine start behavior.

import Foundation

#if os(Linux)
extension Mpd.Environment.Action.Start {
    static func preflight(in command: GlobalCommand, machineName _: String) throws {
        _ = command
        try CommandPreflight.check(commandName: "mpd --start", requiredNames: [
            "podman", "sudo", "bash", "ping", "sha256sum",
        ])
    }

    static func execute() throws {
        let fm = FileManager.default
        let status = Mpd.Core.State.readStatus()
        guard !status.activeMachine.isEmpty else {
            throw RuntimeError("mpd is not set up yet. Run: mpd --setup")
        }
        guard fm.fileExists(atPath: Mpd.Core.State.machineDir()) else {
            throw RuntimeError("mpd is not set up yet. Run: mpd --setup")
        }

        // Ensure core services are running. fileaccess first — internal volume
        // ops (rescan, certs, etc.) on later boots may want it available.
        try Mpd.Service.FileAccess.start()

        // Refresh the volume's bind-mount sources from host state. Picks
        // up any user edits to ~/.mpd/mpd-user.env since last run; idempotent
        // on dnsmasq.d. Must come after fileaccess (sync execs through it)
        // and before dnsmasq (which subpath-binds /srv/state/dnsmasq.d).
        step("Syncing bind-mount sources into data volume")
        try Mpd.Core.State.syncBindMountFiles()
        ok("Bind-mount sources synced.")

        try Mpd.Service.Dnsmasq.start()
        try Mpd.Service.Portal.start()
        try Mpd.Service.Adminer.start()

        // Verify DNS resolution health.
        step("DNS resolution")
        Mpd.Environment.Integration.verifyDNS()

        print("""

        \u{001B}[1;32m✓ mpd started.\u{001B}[0m

          https://mpd.test/
          mpd list              show all projects
          mpd start <project>   start a project
        """)
    }
}
#endif
