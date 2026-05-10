// mpd-machine command hooks
// Linux runtime / mpd-machine stop behavior — powers off the VM.

import Foundation

#if os(Linux)
extension Mpd.Environment.Action.Stop {
    static func execute() throws {
        let status = Mpd.Core.State.readStatus()
        guard !status.activeMachine.isEmpty else {
            throw RuntimeError("mpd is not set up yet. Run: mpd --setup")
        }

        // Graceful DB shutdown before poweroff. Without this, the next boot
        // would find postgres doing crash recovery on first start. Failures
        // are logged but never block — `.continue` failure mode.
        step("Firing pre-stop hooks")
        try Mpd.Hooks.fire(EventMpdPreStop(), verb: "stop")

        // Project status is *preserved* across the reboot (persisted intent
        // model — see docs/HOOKS.md §"Resource lifecycle model"). Projects
        // marked running stay running in state, so the next `mpd --start`
        // restores them automatically.

        print("""

        \u{001B}[1;33mPowering off VM\u{001B}[0m
        (your SSH session will drop in a moment)
        """)

        // Test/dev escape hatch: setting MPD_STOP_DOES_NOT_SHUTDOWN_VM
        // lets agents (or anyone) exercise the post-`mpd --stop` flow
        // without losing the SSH session to a real poweroff. Use sparingly
        // — the whole point of `mpd --stop` is normally to power off.
        if let v = ProcessInfo.processInfo.environment["MPD_STOP_DOES_NOT_SHUTDOWN_VM"], !v.isEmpty {
            print("\nMPD_STOP_DOES_NOT_SHUTDOWN_VM is set — skipping VM poweroff.")
            return
        }

        // systemd will SIGTERM podman services (rootful containers get graceful
        // shutdown via the podman.service unit). Passwordless sudo is set up
        // by the platform bootstrap script so this doesn't prompt.
        let rc = Mpd.Environment.HostExec.run(["sudo", "systemctl", "poweroff"])
        if rc != 0 {
            throw RuntimeError("Failed to power off VM (sudo systemctl poweroff returned \(rc)).")
        }
    }
}
#endif
