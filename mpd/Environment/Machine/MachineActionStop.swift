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

        // Persist project status before poweroff. The VM's filesystem keeps the
        // state file across reboots; on next boot 'mpd --start' starts from a
        // consistent baseline.
        step("Updating project statuses")
        var projects = Mpd.Runtime.State.loadProjects()
        var count = 0
        for i in projects.projects.indices where projects.projects[i].status == .running {
            projects.projects[i].status = .stopped
            count += 1
        }
        Mpd.Runtime.State.saveProjects(projects)
        ok(count > 0 ? "Marked \(count) project(s) as stopped." : "No running projects.")

        print("""

        \u{001B}[1;33mPowering off VM\u{001B}[0m
        (your SSH session will drop in a moment)
        """)

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
