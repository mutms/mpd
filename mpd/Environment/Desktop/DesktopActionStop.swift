// mpd-desktop command hooks
// Desktop-only setup/start/stop/uninstall behavior (macOS host + Podman Desktop).

import Foundation

#if os(macOS)
extension Mpd.Environment.Action.Stop {
    
    static func execute() throws {
        let status = Mpd.Core.State.readStatus()
        guard !status.activeMachine.isEmpty else {
            throw RuntimeError("mpd is not set up yet. Run: mpd --setup")
        }

        // Graceful DB shutdown before tearing the Podman machine down.
        // `.continue` failure mode — never blocks the stop sequence.
        step("Firing pre-stop hooks")
        try Mpd.Hooks.fire(EventMpdPreStop(), verb: "stop")

        try Mpd.Environment.PodmanMachine.stop(status.activeMachine)

        // Project status is preserved across mpd --stop / --start
        // (persisted intent model — see docs/HOOKS.md §"Resource lifecycle
        // model"). The next `mpd --start` restores running projects.

        print("\n\u{001B}[1;32m✓ mpd stopped.\u{001B}[0m")
        print("  Restart with: mpd --start")
    }
}
#endif
