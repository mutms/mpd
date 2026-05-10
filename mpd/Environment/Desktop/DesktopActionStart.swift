// mpd-desktop command hooks
// Desktop-only setup/start/stop/uninstall behavior (macOS host + Podman Desktop).

import Foundation

#if os(macOS)
extension Mpd.Environment.Action.Start {
        static func execute() throws {
        // Lightweight daily start — no provisioning, no cert generation, no asset copy.
        // Requires --setup to have been run at least once.
            
        step("Podman Desktop machine")

        let fm = FileManager.default
        let status = Mpd.Core.State.readStatus()
        guard !status.activeMachine.isEmpty else {
            throw RuntimeError("mpd is not set up yet. Run: mpd --setup")
        }
        guard fm.fileExists(atPath: Mpd.Core.State.machineDir()) else {
            throw RuntimeError("mpd is not set up yet. Run: mpd --setup")
        }
         
        try Mpd.Environment.PodmanMachine.start(status.activeMachine)

        // Start service containers. Ordering: WireGuard has its own image
        // and no mpd state dependency. fileaccess must come up before any
        // bind-mount-source sync, since the sync execs through fileaccess.
        // Dnsmasq subpath-binds /srv/state/dnsmasq.d, so the sync has to
        // populate that path before dnsmasq starts.
        try Mpd.Service.WireGuard.start()
        try Mpd.Service.FileAccess.start()

        // Refresh the volume's bind-mount sources from host state. Picks
        // up any user edits to ~/.mpd/mpd-user.env since last run; idempotent
        // on dnsmasq.d.
        step("Syncing bind-mount sources into data volume")
        try Mpd.Core.State.syncBindMountFiles()
        ok("Bind-mount sources synced.")

        try Mpd.Service.Dnsmasq.start()
        try Mpd.Service.Portal.start()
        try Mpd.Service.Adminer.start()

        // Step 3 — WireGuard tunnel (interactive wait, same as --setup)
        step("WireGuard tunnel")
        let wgConf = "\(Mpd.Environment.confWireGuardDir)/mpd-desktop.conf"
        Mpd.Environment.Integration.importWireGuardConfig(confPath: wgConf)
        ok("WireGuard tunnel active.")

        // Step 4 — Verify DNS
        step("Verifying DNS resolution")
        Mpd.Environment.Integration.verifyDNS()

        // Refresh the live-state snapshot (current-state.json) for
        // out-of-process consumers (portal, runtime tools).
        Mpd.Runtime.State.refreshCurrentStateCache()

        print("""

        \u{001B}[1;32m✓ mpd started.\u{001B}[0m

          https://mpd.test/
          mpd list              show all projects
          mpd start <project>   start a project
        """)
    }
}
#endif
