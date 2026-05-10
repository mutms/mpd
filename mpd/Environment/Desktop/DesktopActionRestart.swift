// mpd-desktop command hooks
// Restart the Podman machine, firing graceful pre-stop hooks before
// teardown so DBs flush cleanly. After the machine comes back up, the
// caller can `mpd --start` to bring projects/runtimes back to their
// persisted `requested` state.
//
// (Why not auto-start here? `mpd --start` is the explicit reconciliation
// step; keeping it separate matches `mpd --stop` / `mpd --start` on
// Desktop and makes the lifecycle easy to reason about.)

import Foundation

#if os(macOS)
extension Mpd.Environment.Action.Restart {
    static func execute() throws {
        let status = Mpd.Core.State.readStatus()
        guard !status.activeMachine.isEmpty else {
            throw RuntimeError("mpd is not set up yet. Run: mpd --setup")
        }

        // Graceful DB shutdown via EventMpdPreStop hooks before the
        // Podman machine VM is stopped. `.continue` failure mode —
        // never blocks the restart.
        step("Firing pre-stop hooks")
        try Mpd.Hooks.fire(EventMpdPreStop(), verb: "restart")

        step("Stopping Podman machine")
        try Mpd.Environment.PodmanMachine.stop(status.activeMachine)

        step("Starting Podman machine")
        try Mpd.Environment.PodmanMachine.start(status.activeMachine)

        print("\n\u{001B}[1;32m✓ Podman machine restarted.\u{001B}[0m")
        print("  Run `mpd --start` to restore runtimes and projects.")
    }
}
#endif
