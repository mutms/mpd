// mpd lifecycle command hooks
// VM restart — `sudo systemctl reboot` lets the VM's
// shutdown sequence drive the existing chain:
//   poweroff → mpd.service ExecStop=mpd --stop → EventMpdPreStop hooks
// On boot, mpd.service ExecStart=-mpd --start brings everything back
// to its persisted `requested` state. We don't fire hooks here directly
// — that would fire them twice (once here, once via ExecStop).

import Foundation

extension Mpd.Action.Restart {
    static func execute() throws {
        let status = Mpd.Core.State.readStatus()
        guard !status.activeMachine.isEmpty else {
            throw RuntimeError("mpd is not set up yet. Run: mpd --setup")
        }

        print("""

        \u{001B}[1;33mRebooting VM\u{001B}[0m
        (your SSH session will drop in a moment; mpd auto-starts on boot)
        """)

        // Test/dev escape hatch — same as `mpd --stop`. Useful for
        // exercising the post-reboot reconciliation flow without losing
        // the SSH session.
        if let v = ProcessInfo.processInfo.environment["MPD_STOP_DOES_NOT_SHUTDOWN_VM"], !v.isEmpty {
            print("\nMPD_STOP_DOES_NOT_SHUTDOWN_VM is set — skipping VM reboot.")
            return
        }

        let rc = Mpd.HostExec.run(["sudo", "systemctl", "reboot"])
        if rc != 0 {
            throw RuntimeError("Failed to reboot VM (sudo systemctl reboot returned \(rc)).")
        }
    }
}
